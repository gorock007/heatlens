#!/bin/sh
# Run a command with a timeout, killing the whole process group on expiry.
# Usage: scripts/with-timeout.sh <seconds> <command> [args...]
set -eu

if [ $# -lt 2 ]; then
  echo "usage: $0 <seconds> <command> [args...]" >&2
  exit 2
fi
exec /usr/bin/perl -e '
  $SIG{ALRM}=sub{
    if(defined $pid){
      kill TERM,-$pid;
    }
    select(undef,undef,undef,5);
    if(defined $pid){
      kill KILL,-$pid;
    }
    print STDERR "with-timeout: timed out after $timeout s\n";
    exit 124;
  };
  $timeout=shift @ARGV;
  $pid=fork;
  if($pid==0){ setpgrp(0,0); exec @ARGV; exit 127; }
  alarm $timeout; waitpid($pid,0); alarm 0;
  if($?&127){ exit 128+($?&127); }
  exit $?>>8;
' "$@"
