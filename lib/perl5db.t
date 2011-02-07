#!./perl

BEGIN {
    if (!-c "/dev/null") {
	print "1..0 # Skip: no /dev/null\n";
	exit 0;
    }
my $dev_tty = '/dev/tty';
   $dev_tty = 'TT:' if ($^O eq 'VMS');
    if (!-c $dev_tty) {
	print "1..0 # Skip: no $dev_tty\n";
	exit 0;
    }
    if ($ENV{PERL5DB}) {
	print "1..0 # Skip: \$ENV{PERL5DB} is already set to '$ENV{PERL5DB}'\n";
	exit 0;
    }
}

use Test::More tests => 11;
use Test::PerlRun;
use Config;

sub rc {
    open RC, ">", ".perldb" or die $!;
    print RC @_;
    close(RC);
    # overly permissive perms gives "Must not source insecure rcfile"
    # and hangs at the DB(1> prompt
    chmod 0644, ".perldb";
}

my $target = '../lib/perl5db/t/eval-line-bug';

rc(
    qq|
    &parse_options("NonStop=0 TTY=db.out LineInfo=db.out");
    \n|,

    qq|
    sub afterinit {
	push(\@DB::typeahead,
	    'b 23',
	    'n',
	    'n',
	    'n',
	    'c', # line 23
	    'n',
	    "p \\\@{'main::_<$target'}",
	    'q',
	);
    }\n|,
);

{
    local $ENV{PERLDB_OPTS} = "ReadLine=0";
    perlrun_stdout_is({switches => '-d', file => $target}, '');
}

my $contents;
{
    local $/;
    open I, "<", 'db.out' or die $!;
    $contents = <I>;
    close(I);
}

like($contents, qr/sub factorial/,
    'The ${main::_<filename} variable in the debugger was not destroyed'
);

{
    local $ENV{PERLDB_OPTS} = "ReadLine=0";
    perlrun_stdout_like({switches => '-d',
			 file => '../lib/perl5db/t/lvalue-bug'},
			qr/foo is defined/,
			'lvalue subs work in the debugger');
}

{
    local $ENV{PERLDB_OPTS} = "ReadLine=0 NonStop=1";
    perlrun_stdout_like({switches => '-d',
			 file => '../lib/perl5db/t/symbol-table-bug'},
			qr/Undefined symbols 0/,
			'there are no undefined values in the symbol table');
}

SKIP: {
    skip('This perl has threads, skipping non-threaded debugger tests', 1)
	if $Config{usethreads};
    perlrun_stderr_like({switches => '-dt', code => 0},
			qr/This Perl not built to support threads/,
			'Perl debugger correctly complains that it was not built with threads');
}

SKIP: {
    skip("This perl is not threaded, skipping threaded debugger tests", 1)
	unless $Config{usethreads};

    local $ENV{PERLDB_OPTS} = "ReadLine=0 NonStop=1";
    perlrun_stdout_like({switches => '-dt',
			 file => '../lib/perl5db/t/symbol-table-bug'},
			qr/Undefined symbols 0/,
			'there are no undefined values in the symbol table when running with thread support');
}


# Test [perl #61222]
{
    rc(
        qq|
        &parse_options("NonStop=0 TTY=db.out LineInfo=db.out");
        \n|,

        qq|
        sub afterinit {
            push(\@DB::typeahead,
                'm Pie',
                'q',
            );
        }\n|,
    );

    perlrun_exit_status_is({switches => '-d', file => '../lib/perl5db/t/rt-61222'},
			   0, 'Program exits cleanly');
    my $contents;
    {
        local $/;
        open I, "<", 'db.out' or die $!;
        $contents = <I>;
        close(I);
    }
    unlike($contents, qr/INCORRECT/, "[perl #61222]");
}



# Test for Proxy constants
{
    rc(
        qq|
        &parse_options("NonStop=0 ReadLine=0 TTY=db.out LineInfo=db.out");
        \n|,

        qq|
        sub afterinit {
            push(\@DB::typeahead,
                'm main->s1',
                'q',
            );
        }\n|,
    );

    perlrun_stderr_is({switches => '-d', file => '../lib/perl5db/t/proxy-constants'},
		       "", "proxy constant subroutines");
}


# [perl #66110] Call a subroutine inside a regex
{
    local $ENV{PERLDB_OPTS} = "ReadLine=0 NonStop=1";
    perlrun_stdout_like({switches => '-d', file => '../lib/perl5db/t/rt-66110'},
			qr/All tests successful\./, "[perl #66110]");
}

# taint tests

{
    local $ENV{PERLDB_OPTS} = "ReadLine=0 NonStop=1";
    perlrun_stdout_like({switches => [ '-d', '-T', '-I../lib' ],
			 file => '../lib/perl5db/t/taint'},
			qr/^\[\$\^X]\[done]$/, "taint");
}


# clean up.

END {
    1 while unlink qw(.perldb db.out);
}
