#!/usr/bin/perl
use strict;
use warnings;
use 5.10.0;
use Data::Dumper;
$Data::Dumper::Terse = 1;
$Data::Dumper::Indent = 0;

use DBM::Deep;
use Cwd;

# for now, q size is 1 and each job is independent; no IPC

die "need command to queue, or '-t', '-f', '-c', or '-e'" unless ( @ARGV and $ARGV[0] ne '-h' );

# ----------------------------------------------------------------------
# kinda sorta globals
my ($db);
my $BASE = "$ENV{HOME}/.cache/jq";
-d "$BASE/r" or system("mkdir -p $BASE/r $BASE/d");
db_open();    # may end up waiting for a looooong time

# ----------------------------------------------------------------------
# main

if ( $ARGV[0] eq '-t' ) {
    tail();     # ftail on in-progress output
} elsif ( $ARGV[0] eq '-f' ) {
    flush();    # cat 'done' files, unlink them
} elsif ( $ARGV[0] eq '-c' ) {
    history(0); # print history, all jobs
} elsif ( $ARGV[0] eq '-e' ) {
    history(1); # print history, failed jobs only
} else {
    queue(@ARGV);
}

exit 0;

sub queue {
    my $queued = gen_ts();
    my $sleep_time = 1;
    _log( 0, "[q $$] " . join(" ", @_) );

    db_lock();
    while ($db->{LIMIT} <= $db->{running}) {
        db_unlock();
        _log( 0, "[w $$] sleep $sleep_time" );
        sleep $sleep_time; $sleep_time %= 31; $sleep_time *= 2;
        db_lock();
    }
    # reserve our slot and get out
    $db->{running}++;
    db_unlock();

    _log( 0, "[s $$] " . join(" ", @_) );
    my $started = gen_ts();
    my ($rc, $es) = run($queued, @_);
    my $completed = gen_ts();
    _log( 0, "[e $$] " . join(" ", @_) );

    db_lock();
    $db->{running}--;
    push @{ $db->{history} }, {
        pwd => getcwd(),
        cmd => \@_,
        rc => $rc,
        es => $es,
        queued => $queued,
        started => $started,
        completed => $completed,
    };

    db_unlock();
}

sub run {
    my $queued = shift;
    my $base = "$BASE/r/$$";

    open(my $oldout, ">&STDOUT") or die;
    open(my $olderr, ">&STDERR") or die;
    open( STDIN, "<", "/dev/null");
    open( STDOUT, ">>", "$base.out" );
    open( STDERR, ">>", "$base.err" );

    _log( 0, "$$ starting (queued $queued)" );
    _log( 0, join( " ", "+", @ARGV ) );
    my $rc = system(@ARGV);
    my $es = ($rc == 0 ? 0 : interpret_exit_code());
    _log( 0, "$$ rc=$rc, es=$es" );
    say STDERR "";
    system("mv $base.out $base.err $BASE/d");

    close(STDOUT);
    close(STDERR);
    open(STDOUT, ">&", $oldout) or die;
    open(STDERR, ">&", $olderr) or die;

    return($rc, $es);
}

sub tail {
    for my $f (glob "$BASE/r/*") {
        say "----8<---- $f";
        say `ftail $f`;
    }
}

sub flush {
    for my $f (glob "$BASE/d/*") {
        say "----8<---- $f";
        say `cat $f`;
        unlink $f;
    }
}

sub history {
    my $min_rc = shift;
    my $db2 = $db->export();
    # XXX needs to be refined later
    for ( @{ $db2->{history} } ) {
        next if $_->{rc} < $min_rc;
        say Dumper $_->{cmd};
        say "cd $_->{pwd}; " . join(" ", @{ $_->{cmd} });
        say $_->{rc} . "\t" . $_->{es};
        say "";
    }
}

# ----------------------------------------------------------------------
# service routines

sub db_open {
    # 'new' == 'open' here
    my $dbfile = "$BASE/db";
    $db = DBM::Deep->new(
        file      => $dbfile,
        locking   => 1,
        autoflush => 1,
        num_txns  => 2,                          # else begin_work won't!
    );
    $db->{LIMIT} //= 1;
    $db->{running} //= 0;
}
sub db_lock { $db->lock_exclusive(); }
sub db_unlock { $db->unlock(); }

sub interpret_exit_code {
    if ( $? == -1 ) {
        return sprintf "failed to execute: $!";
    } elsif ( $? & 127 ) {
        return sprintf "child died with signal %d, %s coredump", ( $? & 127 ), ( $? & 128 ) ? 'with' : 'without';
    } else {
        return sprintf "child exited with value %d", $? >> 8;
    }
}

sub gen_ts {
    my ( $s, $m, $h ) = (localtime)[ 0 .. 2 ];
    for ( $s, $m, $h ) {
        $_ = "0$_" if $_ < 10;
    }
    return "$h:$m:$s";
}

sub _log {
    my ( $lvl, $msg ) = @_;
    return if $lvl > ( $ENV{D} || 0 );
    say STDERR "[" . gen_ts . "] $msg";
}
