package Minion::Backend::mysql;

use 5.010;

use Mojo::Base 'Minion::Backend';

use Mojo::IOLoop;
use Mojo::JSON qw(encode_json decode_json);
use Mojo::mysql;
use Scalar::Util qw(blessed);
use Sys::Hostname 'hostname';
use Time::Piece ();

has 'mysql';

our $VERSION = '0.17';

sub dequeue {
  my ($self, $worker_id, $wait, $options) = @_;

  if ((my $job = $self->_try($worker_id, $options))) { return $job }
  return undef if Mojo::IOLoop->is_running;

  my $cb = $self->mysql->pubsub->listen("minion.job" => sub {
    Mojo::IOLoop->stop;
  });

  my $timer = Mojo::IOLoop->timer($wait => sub { Mojo::IOLoop->stop });
  Mojo::IOLoop->start;

  $self->mysql->pubsub->unlisten("minion.job" => $cb) and Mojo::IOLoop->remove($timer);

  return $self->_try($worker_id, $options);
}

sub history {
  my $self = shift;

  my $sql = <<SQL;
SELECT
  MIN(UNIX_TIMESTAMP(finished)) as `epoch`,
  DAY(finished) as `day`,
  HOUR(finished) as `hour`,
  SUM(CASE state WHEN 'failed' THEN 1 ELSE 0 END) AS failed_jobs,
  SUM(CASE state WHEN 'finished' THEN 1 ELSE 0 END) AS finished_jobs
FROM minion_jobs
WHERE finished > SUBTIME(NOW(), '23:00:00')
GROUP BY `day`, `hour`
ORDER BY `day`, `hour`
SQL

  my $data = $self->mysql->db->query($sql)->hashes;

  # Fill in missing hours to create a full time series
  my $now = Time::Piece->new();
  my $current_hour = $now->hour;
  for my $i ( 0..23 ) {
    my $i_hour = ( $current_hour - ( 23 - $i ) ) % 24;
    if ( exists $data->[$i] and $data->[ $i ]{ hour } != $i_hour ) {
      my $epoch = $now->epoch - ( 3600 * ( 24 - $i ) );
      splice @$data, $i, 0, {
        epoch => $epoch - ( $epoch % 3600 ),
        failed_jobs => 0,
        finished_jobs => 0,
      };
    }
    else {
      delete $data->[ $i ]{hour};
      delete $data->[ $i ]{day};
    }
  }

  return {daily => $data};
}

sub enqueue {
  my ($self, $task) = (shift, shift);
  my $args    = shift // [];
  my $options = shift // {};

  my $db = $self->mysql->db;

  my $seconds = $db->dbh->quote($options->{delay} // 0);
  $db->query(
    "insert into minion_jobs (`args`, `attempts`, `delayed`, `priority`, `queue`, `task`, `notes`)
     values (?, ?, (DATE_ADD(NOW(), INTERVAL $seconds SECOND)), ?, ?, ?, ?)",
     encode_json($args), $options->{attempts} // 1,
     $options->{priority} // 0, $options->{queue} // 'default', $task,
     encode_json( $options->{notes} // {} ),
  );
  my $job_id = $db->dbh->{mysql_insertid};

  if ( my @parents = @{ $options->{parents} || [] } ) {
    $db->query(
      "INSERT IGNORE INTO minion_jobs_depends (`parent_id`, `child_id`) VALUES "
      . join( ", ", map "( ?, ? )", @parents ),
      map { $_, $job_id  } @parents
    );
  }

  $self->mysql->pubsub->notify("minion.job" => $job_id);

  return $job_id;
}

sub note {
  my ($self, $id, $merge) = @_;
  my $db = $self->mysql->db;
  my $job = $db->query(
    'SELECT notes FROM minion_jobs WHERE id=?', $id,
  )->hash || return 0;
  my $notes = decode_json( $job->{notes} );
  foreach my $key (keys %$merge){
      $notes->{ $key } = $merge->{$key};
  }
  return !!$db->query(
    'UPDATE minion_jobs SET notes = ? WHERE id = ?',
    encode_json( $notes ), $id,
  )->rows;
}

sub fail_job   { shift->_update(1, @_) }
sub finish_job { shift->_update(0, @_) }

sub list_jobs {
  my ($self, $offset, $limit, $options) = @_;

  my ( @where, @params );
  if ( my $states = $options->{states} ) {
    push @where, 'state in (' . join( ',', ('?') x @$states ) . ')';
    push @params, @$states;
  }
  if ( my $queues = $options->{queues} ) {
    push @where, 'queue in (' . join( ',', ('?') x @$queues ) . ')';
    push @params, @$queues;
  }
  if ( my $tasks = $options->{tasks} ) {
    push @where, 'task in (' . join( ',', ('?') x @$tasks ) . ')';
    push @params, @$tasks;
  }
  if ( my $ids = $options->{ids} ) {
    push @where, 'id in (' . join( ',', ('?') x @$ids ) . ')';
    push @params, @$ids;
  }

  my $where = @where ? 'WHERE ' . join( ' AND ', @where ) : '';

  my $db = $self->mysql->db;

  # Note: The GROUP BY below only needs minion_jobs.id, child_jobs.parent_id,
  # and parent_jobs.child_id - the additional redundant columns are just
  # there to satisfy the ONLY_FULL_GROUP_BY requirement in MySQL strict mode.
  #
  my $jobs = $db->query(
    "SELECT
      id, args, attempts,
      UNIX_TIMESTAMP(created) AS created,
      UNIX_TIMESTAMP(`delayed`) AS `delayed`,
      UNIX_TIMESTAMP(finished) AS finished, priority,
      queue, result, UNIX_TIMESTAMP(retried) AS retried, retries,
      UNIX_TIMESTAMP(started) AS started, state, task,
      GROUP_CONCAT( child_jobs.child_id SEPARATOR ':' ) AS children,
      GROUP_CONCAT( parent_jobs.parent_id SEPARATOR ':' ) AS parents,
      worker, notes
    FROM minion_jobs
    LEFT JOIN minion_jobs_depends child_jobs ON minion_jobs.id=child_jobs.parent_id
    LEFT JOIN minion_jobs_depends parent_jobs ON minion_jobs.id=parent_jobs.child_id
    $where
    GROUP BY minion_jobs.id, child_jobs.parent_id, parent_jobs.child_id
           , minion_jobs.args, minion_jobs.attempts, minion_jobs.created,
             minion_jobs.delayed, minion_jobs.finished, minion_jobs.notes,
             minion_jobs.priority, minion_jobs.queue, minion_jobs.result,
             minion_jobs.retried, minion_jobs.retries, minion_jobs.started,
             minion_jobs.state, minion_jobs.task, minion_jobs.worker
    ORDER BY id DESC
    LIMIT ?
    OFFSET ?", @params, $limit, $offset,
  )->hashes;
  $jobs->map( _decode_json_fields(qw{ args result notes }) )
    ->each( sub {
      $_->{children} = [ split /:/, $_->{children} // '' ];
      $_->{parents} = [ split /:/, $_->{parents} // '' ];
    } );

  #; use Data::Dumper;
  #; say Dumper $jobs;

  my $total = $db->query(
    'SELECT COUNT(*) AS count FROM minion_jobs',
  )->hash->{count};

  return {
    jobs => $jobs,
    total => $total,
  }
}

sub _decode_json_fields {
  my @fields = @_;
  return sub {
    my $hash = shift;
    for my $field ( @fields ) {
      next unless $hash->{ $field };
      $hash->{ $field } = decode_json( $hash->{ $field } );
    }
    return $hash;
  };
}

sub list_workers {
  my ($self, $offset, $limit, $options) = @_;

  my ( @where, @params );
  if ( my $ids = $options->{ids} ) {
    push @where, 'id in (' . join( ',', ('?') x @{$options->{ids}} ) . ')';
    push @params, @{ $options->{ids} };
  }

  my $db = $self->mysql->db;

  my $where = @where ? 'WHERE ' . join ' AND ', @where : '';
  my $sql = "SELECT
    id, UNIX_TIMESTAMP(notified) AS notified, host, pid,
    UNIX_TIMESTAMP(started) AS started, status
  FROM minion_workers $where ORDER BY id DESC LIMIT ? OFFSET ?";
  my $workers = $db->query($sql, @params, $limit, $offset)
    ->hashes;

  # Add jobs to each worker
  my $jobs_sql = q{SELECT id FROM minion_jobs WHERE state='active' AND worker=?};
  $workers->map( sub {
      $_->{status} = decode_json( $_->{status} );
      $_->{jobs} = $db->query($jobs_sql, $_->{id})->arrays->flatten->to_array
  } );

  my $total = $db->query(
    'SELECT COUNT(*) AS count FROM minion_workers',
  )->hash->{count};

  return {
    workers => $workers,
    total => $total,
  };
}

sub list_locks {
  my ($self, $offset, $limit, $options) = @_;

  my ( @where, @params );
  if ( my $name = $options->{names} // $options->{name} ) {
    my @names = ref $name eq 'ARRAY' ? @$name : ( $name );
    push @where, 'name in (' . join( ',', ('?') x @names ) . ')';
    push @params, @names;
  }

  push @where, 'expires > now()';

  my $where = @where ? 'WHERE ' . join ' AND ', @where : '';
  my $sql = "SELECT
          id, name, UNIX_TIMESTAMP(expires) AS expires
      FROM minion_locks
      $where
      ORDER BY id
      DESC LIMIT ? OFFSET ?";

  my $db = $self->mysql->db;

  my $locks = $db->query($sql, @params, $limit || 0, $offset || 0)->hashes;

  my $total = $db->query(
    "SELECT COUNT(name) AS total FROM minion_locks $where", @params
  )->hash->{total};

  return {
    locks => $locks,
    total => $total,
  };
}

sub new {
  my ( $class, @args ) = @_;

  my $mysql;
  my $force_migration = 0;
  if ( @args == 1 && blessed($args[0]) && $args[0]->isa('Mojo::mysql') ) {
    $mysql = $args[0];
    $force_migration = 1;
  }
  else {
    if ( ref $args[0] eq 'HASH' ) {
      @args = %{ $args[0] };
    }
    $mysql = Mojo::mysql->new(@args);
  }

  my $self = $class->SUPER::new(mysql => $mysql);

  if ($force_migration) {

    # First make sure any impending migrations happen
    # before we overwrite them:
    $mysql->migrations->migrate;

    # Then load this module's migrations and run them:
    $mysql->migrations->name('minion')->from_data;
    $mysql->migrations->migrate;
  }
  else {
    # Load this module's migrations and run them
    # the first time a DB connection is attempted:
    $mysql->migrations->name('minion')->from_data;
    $mysql->once(connection => sub { shift->migrations->migrate });
  }

  return $self;
}

sub register_worker {
  my ($self, $id, $options) = @_;

  my $db = $self->mysql->db;
  my $sql = q{INSERT INTO minion_workers (id, host, pid, status)
    VALUES (?, ?, ?, ?)
    ON DUPLICATE KEY UPDATE notified=NOW(), host=VALUES(host), pid=VALUES(pid), status=VALUES(status)};
  $db->query($sql, $id, hostname, $$, encode_json( $options->{status} // {} ) );

  return $id // $db->dbh->{mysql_insertid};
}

sub remove_job {
  !!shift->mysql->db->query(
    "delete from minion_jobs
     where id = ? and state in ('inactive', 'failed', 'finished')",
     shift
  )->{affected_rows};
}

sub repair {
  my $self = shift;

  # Check worker registry
  my $db     = $self->mysql->db;
  my $minion = $self->minion;
  $db->query(
    "delete from minion_workers
     where notified < (DATE_SUB(NOW(), INTERVAL ? SECOND))",
     $minion->missing_after
  );

  # Abandoned jobs
  my $fail = $db->query(
    "select id, retries from minion_jobs as j
     where state = 'active'
       and not exists (select 1 from minion_workers where id = j.worker)"
  )->hashes;
  $fail->each(sub { $self->fail_job(@$_{qw(id retries)}, 'Worker went away') });

  # Old jobs with no unresolved dependencies
  $db->query( q{
    DELETE FROM minion_jobs
    WHERE state = 'finished'
      AND finished <= (DATE_SUB(NOW(), INTERVAL ? SECOND))
      AND state='finished'
      AND NOT EXISTS (
        SELECT 1 FROM ( SELECT id, state FROM minion_jobs ) AS child
        LEFT JOIN minion_jobs_depends depends ON child.id=depends.child_id
        WHERE parent_id=minion_jobs.id AND child.state != 'finished'
      )
    }, $minion->remove_after,
  );

}

sub reset {
    my $self = shift;

    my $mysql = $self->mysql;
    $mysql->db->query("delete from minion_jobs");
    $mysql->db->query("truncate table minion_locks");
    $mysql->db->query("truncate table minion_workers");
}

sub lock {
  my ($self, $name, $duration, $options) = (shift, shift, shift, shift // {});
  return !!$self->mysql->db->query('SELECT minion_lock(?, ?, ?)',
    $name, $duration, $options->{limit} || 1)->array->[0];
}

sub unlock {
  !!shift->mysql->db->query(
    'DELETE FROM minion_locks
      WHERE expires > NOW() AND name = ? ORDER BY EXPIRES
      LIMIT 1', shift
  )->rows;
}

sub retry_job {
  my ($self, $id, $retries) = (shift, shift, shift);
  my $db = $self->mysql->db;
  my $options = shift // {};

  my $seconds = $db->dbh->quote($options->{delay} // 0);

  if ( my $parents = delete $options->{ parents } ) {
    $db->query(
      'DELETE FROM `minion_jobs_depends` WHERE child_id=?',
      $id,
    );
    if ( @$parents ) {
      $db->query(
        "INSERT INTO minion_jobs_depends (`parent_id`, `child_id`) VALUES "
        . join( ", ", map "( ?, ? )", @$parents ),
        map { $_, $id  } @$parents
      );
    }
  }

  return !!$db->query(
    "UPDATE `minion_jobs`
     SET attempts = COALESCE(?, attempts),
       `delayed` = DATE_ADD(NOW(), INTERVAL $seconds SECOND),
       priority = COALESCE(?, priority), queue = COALESCE(?, queue),
       retried = NOW(), retries = retries + 1, state = 'inactive'
     WHERE id = ? AND retries = ?",
     $options->{attempts},
     @$options{qw(priority queue)}, $id, $retries
  )->{affected_rows};
}

sub stats {
  my $self = shift;

  my $db  = $self->mysql->db;
  my $all = $db->query('select count(*) from minion_workers')->array->[0];
  my $sql
    = "select count(distinct worker) from minion_jobs where state = 'active'";
  my $active = $db->query($sql)->array->[0];

  #### TODO: odd $a and $b weren't working, or something
  $sql = 'select state, count(state) from minion_jobs group by 1';
  my $results
    = $db->query($sql); # ->reduce(sub { $a->{$b->[0]} = $b->[1]; $a }, {});

  my $states = {};
  while (my $next = $results->array) {
    $states->{$next->[0]} = $next->[1];
  }

  my $uptime = $db->query( "SHOW GLOBAL STATUS LIKE 'Uptime'" )->hash->{Value};

  $sql = q{
    SELECT
      SUM(CASE WHEN `state` = 'inactive' AND `delayed` > NOW() THEN 1 ELSE 0 END) AS delayed_jobs,
      COUNT(*) AS enqueued_jobs
      FROM minion_jobs
    };
  %$states = ( %$states, %{ $db->query($sql)->hash } );
  $states->{active_locks} = $db->query("SELECT COUNT(*) FROM minion_locks WHERE expires > now()")->array->[0];

  return {
    active_workers   => $active,
    inactive_workers => $all - $active,
    active_jobs      => $states->{active} || 0,
    inactive_jobs    => $states->{inactive} || 0,
    failed_jobs      => $states->{failed} || 0,
    finished_jobs    => $states->{finished} || 0,
    enqueued_jobs    => $states->{enqueued_jobs} || 0,
    delayed_jobs     => $states->{delayed_jobs} || 0,
    active_locks     => $states->{active_locks} || 0,
    uptime           => $uptime || 0,
  };
}

sub unregister_worker {
  shift->mysql->db->query('delete from minion_workers where id = ?', shift);
}

sub _try {
  my ($self, $worker_id, $options) = @_;

  my $tasks = [keys %{$self->minion->tasks}];

  return unless @$tasks;

  my $queues = $options->{queues} // ['default'];

  my $qq = join ", ", map({ "?" } @$queues);
  my $qt = join ", ", map({ "?" } @$tasks );

  my $dbh = $self->mysql->db->dbh;

  # Try to update a job and mark it as being active for this worker.
  # If we succeed, the job_id of the updated job will be stored in
  # the "@dequeued_job_id" variable:
  #
  my $affected_rows = $dbh->do(qq{
    UPDATE minion_jobs job
    SET job.started = NOW(), job.state = 'active', job.worker = ?,
        job.id = \@dequeued_job_id := job.id
    WHERE job.state = 'inactive' AND job.`delayed` <= NOW()
      AND NOT EXISTS (
        SELECT 1 FROM minion_jobs_depends depends
        LEFT JOIN ( SELECT id, state FROM minion_jobs WHERE state IN ( 'inactive', 'active', 'failed' )) AS parent ON parent.id=depends.parent_id
        WHERE child_id=job.id AND parent.id=depends.parent_id AND parent.state IN ( 'inactive', 'active', 'failed' )
      )
      AND job.queue IN ($qq) AND job.task IN ($qt)
    ORDER BY job.priority DESC, job.created
    LIMIT 1
   },
   {}, $worker_id, @$queues, @$tasks
  );

  return if $affected_rows == 0;   # DBIC returns 0E0 if no rows

  my $job = $dbh->selectrow_hashref(
    'SELECT id, args, retries, task FROM minion_jobs where id = @dequeued_job_id'
  );

  #; use Data::Dumper;
  #; say "Dequeuing job: " . Dumper $job;

  $job->{args} = $job->{args} ? decode_json($job->{args}) : undef;

  return $job;
}

sub _update {
  my ($self, $fail, $id, $retries, $result) = @_;
  my $updated = $self->mysql->db->query(
    "update minion_jobs
     set finished = now(), result = ?, state = ?
     where id = ? and retries = ? and state = 'active'",
     encode_json($result), $fail ? 'failed' : 'finished', $id,
    $retries
  )->{affected_rows};
  #; say "Updated $updated job rows (id: $id, fail: $fail, result: @{[encode_json( $result )]})";
  return undef unless $updated;

  return 1 if !$fail;    # finished

  my $job = $self->list_jobs( 0, 1, { ids => [$id] } )->{jobs}[0];
  return 1 if (my $attempts = $job->{attempts}) == 1;
  return 1 if $retries >= ( $attempts - 1 );

  my $delay = $self->minion->backoff->( $retries );
  return $self->retry_job( $id, $retries, { delay => $delay } );
}

sub broadcast {
  my ($self, $command, $args, $ids) = (shift, shift, shift || [], shift || []);

  my $db = $self->mysql->db;

  my $message = encode_json( [ $command, @$args ] );
  if ( !@$ids ) {
    @$ids = map { $_->{id} }
      @{ $db->query( 'SELECT id FROM minion_workers' )->hashes },
  }
  my $rows = 0;
  for my $id ( @$ids ) {
    $rows += $db->query(
      'INSERT INTO minion_workers_inbox ( worker_id, message ) VALUES ( ?, ? )',
      $id, $message,
    )->rows;
  }
  return $rows;
}

sub receive {
  my ($self, $worker_id) = @_;
  #; use Data::Dumper;
  my $db = $self->mysql->db;
  my $rows = $db->query(
    'SELECT id, message FROM minion_workers_inbox WHERE worker_id=?', $worker_id,
  )->hashes;
  return [] unless $rows && @$rows;
  #; say Dumper $rows;
  my @ids = map { $_->{id} } @$rows;
  #; say Dumper \@ids;
  $db->query(
    'DELETE FROM minion_workers_inbox WHERE id IN (' . ( join ", ", ( '?' ) x @ids ) . ')',
    @ids,
  );
  return [ map { decode_json( $_->{message} ) } @$rows ];
}

1;

=encoding utf8

=head1 NAME

Minion::Backend::mysql - MySQL backend

=head1 SYNOPSIS

  use Mojolicious::Lite;

  plugin Minion => {mysql => 'mysql://user@127.0.0.1/minion_jobs'};

  # Slow task
  app->minion->add_task(poke_mojo => sub {
    my $job = shift;
    $job->app->ua->get('mojolicio.us');
    $job->app->log->debug('We have poked mojolicio.us for a visitor');
  });

  # Perform job in a background worker process
  get '/' => sub {
    my $c = shift;
    $c->minion->enqueue('poke_mojo');
    $c->render(text => 'We will poke mojolicio.us for you soon.');
  };

  app->start;

=head1 DESCRIPTION

L<Minion::Backend::mysql> is a backend for L<Minion> based on L<Mojo::mysql>. All
necessary tables will be created automatically with a set of migrations named
C<minion>. This backend requires at least v5.6.5 of MySQL.

=head1 ATTRIBUTES

L<Minion::Backend::mysql> inherits all attributes from L<Minion::Backend> and
implements the following new ones.

=head2 mysql

  my $mysql   = $backend->mysql;
  $backend = $backend->mysql(Mojo::mysql->new);

L<Mojo::mysql> object used to store all data.

=head1 METHODS

L<Minion::Backend::mysql> inherits all methods from L<Minion::Backend> and
implements the following new ones.

=head2 dequeue

  my $job_info = $backend->dequeue($worker_id, 0.5);
  my $job_info = $backend->dequeue($worker_id, 0.5, {queues => ['important']});

Wait for job, dequeue it and transition from C<inactive> to C<active> state or
return C<undef> if queues were empty.

These options are currently available:

=over 2

=item queues

  queues => ['important']

One or more queues to dequeue jobs from, defaults to C<default>.

=back

These fields are currently available:

=over 2

=item args

  args => ['foo', 'bar']

Job arguments.

=item id

  id => '10023'

Job ID.

=item retries

  retries => 3

Number of times job has been retried.

=item task

  task => 'foo'

Task name.

=back

=head2 enqueue

  my $job_id = $backend->enqueue('foo');
  my $job_id = $backend->enqueue(foo => [@args]);
  my $job_id = $backend->enqueue(foo => [@args] => {priority => 1});

Enqueue a new job with C<inactive> state.

These options are currently available:

=over 2

=item delay

  delay => 10

Delay job for this many seconds (from now).

=item priority

  priority => 5

Job priority, defaults to C<0>.

=item queue

  queue => 'important'

Queue to put job in, defaults to C<default>.

=back

=head2 fail_job

  my $bool = $backend->fail_job($job_id, $retries);
  my $bool = $backend->fail_job($job_id, $retries, 'Something went wrong!');
  my $bool = $backend->fail_job(
    $job_id, $retries, {msg => 'Something went wrong!'});

Transition from C<active> to C<failed> state.

=head2 finish_job

  my $bool = $backend->finish_job($job_id, $retries);
  my $bool = $backend->finish_job($job_id, $retries, 'All went well!');
  my $bool = $backend->finish_job($job_id, $retries, {msg => 'All went well!'});

Transition from C<active> to C<finished> state.

=head2 job_info

  my $job_info = $backend->job_info($job_id);

Get information about a job or return C<undef> if job does not exist.

  # Check job state
  my $state = $backend->job_info($job_id)->{state};

  # Get job result
  my $result = $backend->job_info($job_id)->{result};

These fields are currently available:

=over 2

=item args

  args => ['foo', 'bar']

Job arguments.

=item created

  created => 784111777

Time job was created.

=item delayed

  delayed => 784111777

Time job was delayed to.

=item finished

  finished => 784111777

Time job was finished.

=item priority

  priority => 3

Job priority.

=item queue

  queue => 'important'

Queue name.

=item result

  result => 'All went well!'

Job result.

=item retried

  retried => 784111777

Time job has been retried.

=item retries

  retries => 3

Number of times job has been retried.

=item started

  started => 784111777

Time job was started.

=item state

  state => 'inactive'

Current job state, usually C<active>, C<failed>, C<finished> or C<inactive>.

=item task

  task => 'foo'

Task name.

=item worker

  worker => '154'

Id of worker that is processing the job.

=back

=head2 list_jobs

  my $batch = $backend->list_jobs($offset, $limit);
  my $batch = $backend->list_jobs($offset, $limit, {states => 'inactive'});

Returns the same information as L</"job_info"> but in batches.

These options are currently available:

=over 2

=item state

  state => 'inactive'

List only jobs in this state.

=item task

  task => 'test'

List only jobs for this task.

=back

=head2 list_workers

  my $batch = $backend->list_workers($offset, $limit);

Returns the same information as L</"worker_info"> but in batches.

=head2 new

  my $backend = Minion::Backend::mysql->new('mysql://mysql@/test');

Construct a new L<Minion::Backend::mysql> object.

=head2 register_worker

  my $worker_id = $backend->register_worker;
  my $worker_id = $backend->register_worker($worker_id);

Register worker or send heartbeat to show that this worker is still alive.

=head2 remove_job

  my $bool = $backend->remove_job($job_id);

Remove C<failed>, C<finished> or C<inactive> job from queue.

=head2 repair

  $backend->repair;

Repair worker registry and job queue if necessary.

=head2 reset

  $backend->reset;

Reset job queue.

=head2 retry_job

  my $bool = $backend->retry_job($job_id, $retries);
  my $bool = $backend->retry_job($job_id, $retries, {delay => 10});

Transition from C<failed> or C<finished> state back to C<inactive>.

These options are currently available:

=over 2

=item delay

  delay => 10

Delay job for this many seconds (from now).

=item parents

  parents => [$id1, $id2, $id3]

Jobs this job depends on.

=item priority

  priority => 5

Job priority.

=item queue

  queue => 'important'

Queue to put job in.

=back

=head2 stats

  my $stats = $backend->stats;

Get statistics for jobs and workers.

=head2 unregister_worker

  $backend->unregister_worker($worker_id);

Unregister worker.

=head2 worker_info

  my $worker_info = $backend->worker_info($worker_id);

Get information about a worker or return C<undef> if worker does not exist.

  # Check worker host
  my $host = $backend->worker_info($worker_id)->{host};

These fields are currently available:

=over 2

=item host

  host => 'localhost'

Worker host.

=item jobs

  jobs => ['10023', '10024', '10025', '10029']

Ids of jobs the worker is currently processing.

=item notified

  notified => 784111777

Last time worker sent a heartbeat.

=item pid

  pid => 12345

Process id of worker.

=item started

  started => 784111777

Time worker was started.

=back

=head1 SEE ALSO

L<Minion>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut

__DATA__

@@ minion
-- 1 up
create table if not exists minion_jobs (
		`id`       serial not null primary key,
		`args`     mediumblob not null,
		`created`  timestamp not null default current_timestamp,
		`delayed`  timestamp not null default current_timestamp,
		`finished` timestamp null,
		`priority` int not null,
		`result`   mediumblob,
		`retried`  timestamp null,
		`retries`  int not null default 0,
		`started`  timestamp null,
		`state`    varchar(128) not null default 'inactive',
		`task`     text not null,
		`worker`   bigint
);

create table if not exists minion_workers (
		`id`      serial not null primary key,
		`host`    text not null,
		`pid`     int not null,
		`started` timestamp not null default current_timestamp,
		`notified` timestamp not null default current_timestamp
);

-- 1 down
drop table if exists minion_jobs;
drop table if exists minion_workers;

-- 2 up
create index minion_jobs_state_idx on minion_jobs (state);

-- 3 up
alter table minion_jobs add queue varchar(128) not null default 'default';

-- 4 up
ALTER TABLE minion_workers MODIFY COLUMN started timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP;
ALTER TABLE minion_workers MODIFY COLUMN notified timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP;
CREATE TABLE IF NOT EXISTS minion_workers_inbox (
  `id` SERIAL NOT NULL PRIMARY KEY,
  `worker_id` BIGINT UNSIGNED NOT NULL,
  `message` BLOB NOT NULL
);
ALTER TABLE minion_jobs ADD COLUMN attempts INT NOT NULL DEFAULT 1;

-- 5 up
ALTER TABLE minion_jobs MODIFY COLUMN args MEDIUMBLOB NOT NULL;
ALTER TABLE minion_jobs MODIFY COLUMN result MEDIUMBLOB;

-- 6 up
ALTER TABLE minion_workers ADD COLUMN status MEDIUMBLOB;
ALTER TABLE minion_jobs ADD COLUMN notes MEDIUMBLOB;
CREATE TABLE IF NOT EXISTS minion_locks (
  id      SERIAL NOT NULL PRIMARY KEY,
  -- InnoDB index prefix limit is 767 bytes, and if you're using
  -- utf8mb4 that means the maximum length is (767 / 4) characters
  name    VARCHAR(191) NOT NULL,
  expires TIMESTAMP NOT NULL,
  INDEX (name, expires)
);
DELIMITER //
CREATE FUNCTION minion_lock( $1 VARCHAR(191), $2 INTEGER, $3 INTEGER) RETURNS BOOL
BEGIN
  DECLARE new_expires TIMESTAMP DEFAULT DATE_ADD( NOW(), INTERVAL 1*$2 SECOND );
  DELETE FROM minion_locks WHERE expires < NOW();
  IF (SELECT COUNT(*) >= $3 FROM minion_locks WHERE name = $1)
  THEN
    RETURN FALSE;
  END IF;
  IF new_expires > NOW()
  THEN
    INSERT INTO minion_locks (name, expires) VALUES ($1, new_expires);
  END IF;
  RETURN TRUE;
END
//
DELIMITER ;
CREATE TABLE minion_jobs_depends (
  parent_id BIGINT UNSIGNED NOT NULL,
  child_id BIGINT UNSIGNED NOT NULL,
  FOREIGN KEY (parent_id) REFERENCES minion_jobs(id) ON DELETE CASCADE,
  FOREIGN KEY (child_id) REFERENCES minion_jobs(id) ON DELETE CASCADE
);

-- 6 down
ALTER TABLE minion_workers DROP COLUMN status;
ALTER TABLE minion_jobs DROP COLUMN notes;
DROP TABLE IF EXISTS minion_locks;
DROP FUNCTION IF EXISTS minion_lock;
DROP TABLE minion_jobs_depends;
