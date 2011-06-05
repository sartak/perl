package ExtUtils::ParseXS;
use strict;

use 5.006;  # We use /??{}/ in regexes
use Cwd;
use Config;
use Exporter;
use File::Basename;
use File::Spec;
use Symbol;
use ExtUtils::ParseXS::Constants ();
use ExtUtils::ParseXS::CountLines;
use ExtUtils::ParseXS::Utilities qw(
  standard_typemap_locations
  trim_whitespace
  tidy_type
  C_string
  valid_proto_string
  process_typemaps
  make_targetable
  map_type
);

our @ISA = qw(Exporter);
our @EXPORT_OK = qw(
  process_file
  report_error_count
);
our $VERSION = '3';
$VERSION = eval $VERSION if $VERSION =~ /_/;

our (
  # The scalars in the line below remain as 'our' variables because pulling
  # them into $self led to build problems.  In most cases, strings being
  # 'eval'-ed contain the variables' names hard-coded.
  $FH, $Package, $func_name, $Full_func_name, $Packid,  $pname,
  @InitFileCode, 
  %IncludedFiles, %input_expr, %output_expr, 
  %type_kind, %proto_letter, 
  @line, %args_match, %defaults, %var_types, %arg_list, @proto_arg,
  %argtype_seen, %in_out, %lengthof, 
  @line_no, 
  %XsubAliases, %XsubAliasValues, %Interfaces, @Attributes, %outargs, 
  $condnum, $cond,
  @XSStack, $ALIAS, 
);
our ($DoSetMagic, $newXS, $proto, $Module_cname, $XsubAliases, $Interfaces, $var_num, );

our $self = {};

sub process_file {

  # Allow for $package->process_file(%hash) in the future
  my ($pkg, %options) = @_ % 2 ? @_ : (__PACKAGE__, @_);

  $self->{ProtoUsed} = exists $options{prototypes};

  # Set defaults.
  my %args = (
    argtypes        => 1,
    csuffix         => '.c',
    except          => 0,
    hiertype        => 0,
    inout           => 1,
    linenumbers     => 1,
    optimize        => 1,
    output          => \*STDOUT,
    prototypes      => 0,
    typemap         => [],
    versioncheck    => 1,
    %options,
  );
  $args{except} = $args{except} ? ' TRY' : '';

  # Global Constants

  my ($Is_VMS, $SymSet);
  if ($^O eq 'VMS') {
    $Is_VMS = 1;
    # Establish set of global symbols with max length 28, since xsubpp
    # will later add the 'XS_' prefix.
    require ExtUtils::XSSymSet;
    $SymSet = new ExtUtils::XSSymSet 28;
  }
  @XSStack = ({type => 'none'});
  my $XSS_work_idx = 0;
  my $cpp_next_tmp = 'XSubPPtmpAAAA';
  @InitFileCode = @ExtUtils::ParseXS::Constants::InitFileCode;
  $FH           = $ExtUtils::ParseXS::Constants::FH;
  $self->{Overload}     = $ExtUtils::ParseXS::Constants::Overload;
  $self->{errors}       = $ExtUtils::ParseXS::Constants::errors;
  $self->{Fallback}     = $ExtUtils::ParseXS::Constants::Fallback;

  # Most of the 1500 lines below uses these globals.  We'll have to
  # clean this up sometime, probably.  For now, we just pull them out
  # of %args.  -Ken

  $self->{hiertype} = $args{hiertype};
  $self->{WantPrototypes} = $args{prototypes};
  $self->{WantVersionChk} = $args{versioncheck};
  $self->{WantLineNumbers} = $args{linenumbers};

  for my $f ($args{filename}) {
    die "Missing required parameter 'filename'" unless $f;
    $self->{filepathname} = $f;
    ($self->{dir}, $self->{filename}) = (dirname($f), basename($f));
    $self->{filepathname} =~ s/\\/\\\\/g;
    $IncludedFiles{$f}++;
  }

  # Open the output file if given as a string.  If they provide some
  # other kind of reference, trust them that we can print to it.
  if (not ref $args{output}) {
    open my($fh), "> $args{output}" or die "Can't create $args{output}: $!";
    $args{outfile} = $args{output};
    $args{output} = $fh;
  }

  # Really, we shouldn't have to chdir() or select() in the first
  # place.  For now, just save & restore.
  my $orig_cwd = cwd();
  my $orig_fh = select();

  chdir($self->{dir});
  my $pwd = cwd();
  my $csuffix = $args{csuffix};

  if ($self->{WantLineNumbers}) {
    my $cfile;
    if ( $args{outfile} ) {
      $cfile = $args{outfile};
    }
    else {
      $cfile = $args{filename};
      $cfile =~ s/\.xs$/$csuffix/i or $cfile .= $csuffix;
    }
    tie(*PSEUDO_STDOUT, 'ExtUtils::ParseXS::CountLines', $cfile, $args{output});
    select PSEUDO_STDOUT;
  }
  else {
    select $args{output};
  }

  my ($type_kind_ref, $proto_letter_ref, $input_expr_ref, $output_expr_ref) =
    process_typemaps( $args{typemap}, $pwd );

  %type_kind    = %{ $type_kind_ref };
  %proto_letter = %{ $proto_letter_ref };
  %input_expr   = %{ $input_expr_ref };
  %output_expr  = %{ $output_expr_ref };

  foreach my $value (values %input_expr) {
    $value =~ s/;*\s+\z//;
    # Move C pre-processor instructions to column 1 to be strictly ANSI
    # conformant. Some pre-processors are fussy about this.
    $value =~ s/^\s+#/#/mg;
  }
  foreach my $value (values %output_expr) {
    # And again.
    $value =~ s/^\s+#/#/mg;
  }

  my %targetable = make_targetable(\%output_expr);

  my $END = "!End!\n\n";        # "impossible" keyword (multiple newline)

  # Match an XS keyword
  $self->{BLOCK_re} = '\s*(' .
    join('|' => @ExtUtils::ParseXS::Constants::keywords) .
    "|$END)\\s*:";

  our ($C_group_rex, $C_arg);
  # Group in C (no support for comments or literals)
  $C_group_rex = qr/ [({\[]
               (?: (?> [^()\[\]{}]+ ) | (??{ $C_group_rex }) )*
               [)}\]] /x;
  # Chunk in C without comma at toplevel (no comments):
  $C_arg = qr/ (?: (?> [^()\[\]{},"']+ )
         |   (??{ $C_group_rex })
         |   " (?: (?> [^\\"]+ )
           |   \\.
           )* "        # String literal
                |   ' (?: (?> [^\\']+ ) | \\. )* ' # Char literal
         )* /xs;

  # Identify the version of xsubpp used
  print <<EOM;
/*
 * This file was generated automatically by ExtUtils::ParseXS version $VERSION from the
 * contents of $self->{filename}. Do not edit this file, edit $self->{filename} instead.
 *
 *    ANY CHANGES MADE HERE WILL BE LOST!
 *
 */

EOM


  print("#line 1 \"$self->{filepathname}\"\n")
    if $self->{WantLineNumbers};

  # Open the input file (using $self->{filename} which
  # is a basename'd $args{filename} due to chdir above)
  open($FH, $self->{filename}) or die "cannot open $self->{filename}: $!\n";

  firstmodule:
  while (<$FH>) {
    if (/^=/) {
      my $podstartline = $.;
      do {
        if (/^=cut\s*$/) {
          # We can't just write out a /* */ comment, as our embedded
          # POD might itself be in a comment. We can't put a /**/
          # comment inside #if 0, as the C standard says that the source
          # file is decomposed into preprocessing characters in the stage
          # before preprocessing commands are executed.
          # I don't want to leave the text as barewords, because the spec
          # isn't clear whether macros are expanded before or after
          # preprocessing commands are executed, and someone pathological
          # may just have defined one of the 3 words as a macro that does
          # something strange. Multiline strings are illegal in C, so
          # the "" we write must be a string literal. And they aren't
          # concatenated until 2 steps later, so we are safe.
          #     - Nicholas Clark
          print("#if 0\n  \"Skipped embedded POD.\"\n#endif\n");
          printf("#line %d \"$self->{filepathname}\"\n", $. + 1)
            if $self->{WantLineNumbers};
          next firstmodule
        }

      } while (<$FH>);
      # At this point $. is at end of file so die won't state the start
      # of the problem, and as we haven't yet read any lines &death won't
      # show the correct line in the message either.
      die ("Error: Unterminated pod in $self->{filename}, line $podstartline\n")
        unless $self->{lastline};
    }
    last if ($Package, $self->{Prefix}) =
      /^MODULE\s*=\s*[\w:]+(?:\s+PACKAGE\s*=\s*([\w:]+))?(?:\s+PREFIX\s*=\s*(\S+))?\s*$/;

    print $_;
  }
  unless (defined $_) {
    warn "Didn't find a 'MODULE ... PACKAGE ... PREFIX' line\n";
    exit 0; # Not a fatal error for the caller process
  }

  print 'ExtUtils::ParseXS::CountLines'->end_marker, "\n" if $self->{WantLineNumbers};

  print <<"EOF";
#ifndef PERL_UNUSED_VAR
#  define PERL_UNUSED_VAR(var) if (0) var = var
#endif

EOF

  print <<"EOF";
#ifndef PERL_ARGS_ASSERT_CROAK_XS_USAGE
#define PERL_ARGS_ASSERT_CROAK_XS_USAGE assert(cv); assert(params)

/* prototype to pass -Wmissing-prototypes */
STATIC void
S_croak_xs_usage(pTHX_ const CV *const cv, const char *const params);

STATIC void
S_croak_xs_usage(pTHX_ const CV *const cv, const char *const params)
{
    const GV *const gv = CvGV(cv);

    PERL_ARGS_ASSERT_CROAK_XS_USAGE;

    if (gv) {
        const char *const gvname = GvNAME(gv);
        const HV *const stash = GvSTASH(gv);
        const char *const hvname = stash ? HvNAME(stash) : NULL;

        if (hvname)
            Perl_croak(aTHX_ "Usage: %s::%s(%s)", hvname, gvname, params);
        else
            Perl_croak(aTHX_ "Usage: %s(%s)", gvname, params);
    } else {
        /* Pants. I don't think that it should be possible to get here. */
        Perl_croak(aTHX_ "Usage: CODE(0x%"UVxf")(%s)", PTR2UV(cv), params);
    }
}
#undef  PERL_ARGS_ASSERT_CROAK_XS_USAGE

#ifdef PERL_IMPLICIT_CONTEXT
#define croak_xs_usage(a,b)    S_croak_xs_usage(aTHX_ a,b)
#else
#define croak_xs_usage        S_croak_xs_usage
#endif

#endif

/* NOTE: the prototype of newXSproto() is different in versions of perls,
 * so we define a portable version of newXSproto()
 */
#ifdef newXS_flags
#define newXSproto_portable(name, c_impl, file, proto) newXS_flags(name, c_impl, file, proto, 0)
#else
#define newXSproto_portable(name, c_impl, file, proto) (PL_Sv=(SV*)newXS(name, c_impl, file), sv_setpv(PL_Sv, proto), (CV*)PL_Sv)
#endif /* !defined(newXS_flags) */

EOF

  print 'ExtUtils::ParseXS::CountLines'->end_marker, "\n" if $self->{WantLineNumbers};

  $self->{lastline}    = $_;
  $self->{lastline_no} = $.;

  my (@BootCode, @outlist, $prepush_done, $xsreturn, $func_header, $orig_args, );
 PARAGRAPH:
  while (fetch_para()) {
    # Print initial preprocessor statements and blank lines
    while (@line && $line[0] !~ /^[^\#]/) {
      my $ln = shift(@line);
      print $ln, "\n";
      next unless $ln =~ /^\#\s*((if)(?:n?def)?|elsif|else|endif)\b/;
      my $statement = $+;
      if ($statement eq 'if') {
        $XSS_work_idx = @XSStack;
        push(@XSStack, {type => 'if'});
      }
      else {
        death ("Error: `$statement' with no matching `if'")
          if $XSStack[-1]{type} ne 'if';
        if ($XSStack[-1]{varname}) {
          push(@InitFileCode, "#endif\n");
          push(@BootCode,     "#endif");
        }

        my(@fns) = keys %{$XSStack[-1]{functions}};
        if ($statement ne 'endif') {
          # Hide the functions defined in other #if branches, and reset.
          @{$XSStack[-1]{other_functions}}{@fns} = (1) x @fns;
          @{$XSStack[-1]}{qw(varname functions)} = ('', {});
        }
        else {
          my($tmp) = pop(@XSStack);
          0 while (--$XSS_work_idx
               && $XSStack[$XSS_work_idx]{type} ne 'if');
          # Keep all new defined functions
          push(@fns, keys %{$tmp->{other_functions}});
          @{$XSStack[$XSS_work_idx]{functions}}{@fns} = (1) x @fns;
        }
      }
    }

    next PARAGRAPH unless @line;

    if ($XSS_work_idx && !$XSStack[$XSS_work_idx]{varname}) {
      # We are inside an #if, but have not yet #defined its xsubpp variable.
      print "#define $cpp_next_tmp 1\n\n";
      push(@InitFileCode, "#if $cpp_next_tmp\n");
      push(@BootCode,     "#if $cpp_next_tmp");
      $XSStack[$XSS_work_idx]{varname} = $cpp_next_tmp++;
    }

    death ("Code is not inside a function"
       ." (maybe last function was ended by a blank line "
       ." followed by a statement on column one?)")
      if $line[0] =~ /^\s/;

    my ($class, $externC, $static, $ellipsis, $wantRETVAL, $RETVAL_no_return);
    my (@fake_INPUT_pre);    # For length(s) generated variables
    my (@fake_INPUT);

    # initialize info arrays
    undef(%args_match);
    undef(%var_types);
    undef(%defaults);
    undef(%arg_list);
    undef(@proto_arg);
    undef($self->{processing_arg_with_types});
    undef(%argtype_seen);
    undef(@outlist);
    undef(%in_out);
    undef(%lengthof);
    undef($self->{proto_in_this_xsub});
    undef($self->{scope_in_this_xsub});
    undef($self->{interface});
    undef($prepush_done);
    $self->{interface_macro} = 'XSINTERFACE_FUNC';
    $self->{interface_macro_set} = 'XSINTERFACE_FUNC_SET';
    $self->{ProtoThisXSUB} = $self->{WantPrototypes};
    $self->{ScopeThisXSUB} = 0;
    $xsreturn = 0;

    $_ = shift(@line);
    while (my $kwd = check_keyword("REQUIRE|PROTOTYPES|FALLBACK|VERSIONCHECK|INCLUDE(?:_COMMAND)?|SCOPE")) {
      no strict 'refs';
      &{"${kwd}_handler"}();
      use strict 'refs';
      next PARAGRAPH unless @line;
      $_ = shift(@line);
    }

    if (check_keyword("BOOT")) {
      &check_cpp;
      push (@BootCode, "#line $line_no[@line_no - @line] \"$self->{filepathname}\"")
        if $self->{WantLineNumbers} && $line[0] !~ /^\s*#\s*line\b/;
      push (@BootCode, @line, "");
      next PARAGRAPH;
    }

    # extract return type, function name and arguments
    ($self->{ret_type}) = tidy_type($_);
    $RETVAL_no_return = 1 if $self->{ret_type} =~ s/^NO_OUTPUT\s+//;

    # Allow one-line ANSI-like declaration
    unshift @line, $2
      if $args{argtypes}
        and $self->{ret_type} =~ s/^(.*?\w.*?)\s*\b(\w+\s*\(.*)/$1/s;

    # a function definition needs at least 2 lines
    blurt ("Error: Function definition too short '$self->{ret_type}'"), next PARAGRAPH
      unless @line;

    $externC = 1 if $self->{ret_type} =~ s/^extern "C"\s+//;
    $static  = 1 if $self->{ret_type} =~ s/^static\s+//;

    $func_header = shift(@line);
    blurt ("Error: Cannot parse function definition from '$func_header'"), next PARAGRAPH
      unless $func_header =~ /^(?:([\w:]*)::)?(\w+)\s*\(\s*(.*?)\s*\)\s*(const)?\s*(;\s*)?$/s;

    ($class, $func_name, $orig_args) =  ($1, $2, $3);
    $class = "$4 $class" if $4;
    ($pname = $func_name) =~ s/^($self->{Prefix})?/$self->{Packprefix}/;
    my $clean_func_name;
    ($clean_func_name = $func_name) =~ s/^$self->{Prefix}//;
    $Full_func_name = "${Packid}_$clean_func_name";
    if ($Is_VMS) {
      $Full_func_name = $SymSet->addsym($Full_func_name);
    }

    # Check for duplicate function definition
    for my $tmp (@XSStack) {
      next unless defined $tmp->{functions}{$Full_func_name};
      Warn("Warning: duplicate function definition '$clean_func_name' detected");
      last;
    }
    $XSStack[$XSS_work_idx]{functions}{$Full_func_name}++;
    %XsubAliases = %XsubAliasValues = %Interfaces = @Attributes = ();
    $DoSetMagic = 1;

    $orig_args =~ s/\\\s*/ /g;    # process line continuations
    my @args;

    my %only_C_inlist;        # Not in the signature of Perl function
    if ($args{argtypes} and $orig_args =~ /\S/) {
      my $args = "$orig_args ,";
      if ($args =~ /^( (??{ $C_arg }) , )* $ /x) {
        @args = ($args =~ /\G ( (??{ $C_arg }) ) , /xg);
        for ( @args ) {
          s/^\s+//;
          s/\s+$//;
          my ($arg, $default) = ($_ =~ m/ ( [^=]* ) ( (?: = .* )? ) /x);
          my ($pre, $len_name) = ($arg =~ /(.*?) \s*
                             \b ( \w+ | length\( \s*\w+\s* \) )
                             \s* $ /x);
          next unless defined($pre) && length($pre);
          my $out_type = '';
          my $inout_var;
          if ($args{inout} and s/^(IN|IN_OUTLIST|OUTLIST|OUT|IN_OUT)\b\s*//) {
            my $type = $1;
            $out_type = $type if $type ne 'IN';
            $arg =~ s/^(IN|IN_OUTLIST|OUTLIST|OUT|IN_OUT)\b\s*//;
            $pre =~ s/^(IN|IN_OUTLIST|OUTLIST|OUT|IN_OUT)\b\s*//;
          }
          my $islength;
          if ($len_name =~ /^length\( \s* (\w+) \s* \)\z/x) {
            $len_name = "XSauto_length_of_$1";
            $islength = 1;
            die "Default value on length() argument: `$_'"
              if length $default;
          }
          if (length $pre or $islength) { # Has a type
            if ($islength) {
              push @fake_INPUT_pre, $arg;
            }
            else {
              push @fake_INPUT, $arg;
            }
            # warn "pushing '$arg'\n";
            $argtype_seen{$len_name}++;
            $_ = "$len_name$default"; # Assigns to @args
          }
          $only_C_inlist{$_} = 1 if $out_type eq "OUTLIST" or $islength;
          push @outlist, $len_name if $out_type =~ /OUTLIST$/;
          $in_out{$len_name} = $out_type if $out_type;
        }
      }
      else {
        @args = split(/\s*,\s*/, $orig_args);
        Warn("Warning: cannot parse argument list '$orig_args', fallback to split");
      }
    }
    else {
      @args = split(/\s*,\s*/, $orig_args);
      for (@args) {
        if ($args{inout} and s/^(IN|IN_OUTLIST|OUTLIST|IN_OUT|OUT)\b\s*//) {
          my $out_type = $1;
          next if $out_type eq 'IN';
          $only_C_inlist{$_} = 1 if $out_type eq "OUTLIST";
          if ($out_type =~ /OUTLIST$/) {
              push @outlist, undef;
          }
          $in_out{$_} = $out_type;
        }
      }
    }
    if (defined($class)) {
      my $arg0 = ((defined($static) or $func_name eq 'new')
          ? "CLASS" : "THIS");
      unshift(@args, $arg0);
    }
    my $extra_args = 0;
    my @args_num = ();
    my $num_args = 0;
    my $report_args = '';
    foreach my $i (0 .. $#args) {
      if ($args[$i] =~ s/\.\.\.//) {
        $ellipsis = 1;
        if ($args[$i] eq '' && $i == $#args) {
          $report_args .= ", ...";
          pop(@args);
          last;
        }
      }
      if ($only_C_inlist{$args[$i]}) {
        push @args_num, undef;
      }
      else {
        push @args_num, ++$num_args;
          $report_args .= ", $args[$i]";
      }
      if ($args[$i] =~ /^([^=]*[^\s=])\s*=\s*(.*)/s) {
        $extra_args++;
        $args[$i] = $1;
        $defaults{$args[$i]} = $2;
        $defaults{$args[$i]} =~ s/"/\\"/g;
      }
      $proto_arg[$i+1] = '$';
    }
    my $min_args = $num_args - $extra_args;
    $report_args =~ s/"/\\"/g;
    $report_args =~ s/^,\s+//;
    my @func_args = @args;
    shift @func_args if defined($class);

    for (@func_args) {
      s/^/&/ if $in_out{$_};
    }
    $self->{func_args} = join(", ", @func_args);
    @args_match{@args} = @args_num;

    my $PPCODE = grep(/^\s*PPCODE\s*:/, @line);
    my $CODE = grep(/^\s*CODE\s*:/, @line);
    # Detect CODE: blocks which use ST(n)= or XST_m*(n,v)
    #   to set explicit return values.
    my $EXPLICIT_RETURN = ($CODE &&
            ("@line" =~ /(\bST\s*\([^;]*=) | (\bXST_m\w+\s*\()/x ));

    # The $ALIAS which follows is only explicitly called within the scope of
    # process_file().  In principle, it ought to be a lexical, i.e., 'my
    # $ALIAS' like the other nearby variables.  However, implementing that
    # change produced a slight difference in the resulting .c output in at
    # least two distributions:  B/BD/BDFOY/Crypt-Rijndael and
    # G/GF/GFUJI/Hash-FieldHash.  The difference is, arguably, an improvement
    # in the resulting C code.  Example:
    # 388c388
    # <                       GvNAME(CvGV(cv)),
    # ---
    # >                       "Crypt::Rijndael::encrypt",
    # But at this point we're committed to generating the *same* C code that
    # the current version of ParseXS.pm does.  So we're declaring it as 'our'.
    $ALIAS  = grep(/^\s*ALIAS\s*:/,  @line);

    my $INTERFACE  = grep(/^\s*INTERFACE\s*:/,  @line);

    $xsreturn = 1 if $EXPLICIT_RETURN;

    $externC = $externC ? qq[extern "C"] : "";

    # print function header
    print Q(<<"EOF");
#$externC
#XS(XS_${Full_func_name}); /* prototype to pass -Wmissing-prototypes */
#XS(XS_${Full_func_name})
#[[
##ifdef dVAR
#    dVAR; dXSARGS;
##else
#    dXSARGS;
##endif
EOF
    print Q(<<"EOF") if $ALIAS;
#    dXSI32;
EOF
    print Q(<<"EOF") if $INTERFACE;
#    dXSFUNCTION($self->{ret_type});
EOF
    if ($ellipsis) {
      $cond = ($min_args ? qq(items < $min_args) : 0);
    }
    elsif ($min_args == $num_args) {
      $cond = qq(items != $min_args);
    }
    else {
      $cond = qq(items < $min_args || items > $num_args);
    }

    print Q(<<"EOF") if $args{except};
#    char errbuf[1024];
#    *errbuf = '\0';
EOF

    if($cond) {
      print Q(<<"EOF");
#    if ($cond)
#       croak_xs_usage(cv,  "$report_args");
EOF
    }
    else {
    # cv likely to be unused
    print Q(<<"EOF");
#    PERL_UNUSED_VAR(cv); /* -W */
EOF
    }

    #gcc -Wall: if an xsub has PPCODE is used
    #it is possible none of ST, XSRETURN or XSprePUSH macros are used
    #hence `ax' (setup by dXSARGS) is unused
    #XXX: could breakup the dXSARGS; into dSP;dMARK;dITEMS
    #but such a move could break third-party extensions
    print Q(<<"EOF") if $PPCODE;
#    PERL_UNUSED_VAR(ax); /* -Wall */
EOF

    print Q(<<"EOF") if $PPCODE;
#    SP -= items;
EOF

    # Now do a block of some sort.

    $condnum = 0;
    $cond = '';            # last CASE: condidional
    push(@line, "$END:");
    push(@line_no, $line_no[-1]);
    $_ = '';
    &check_cpp;
    while (@line) {
      &CASE_handler if check_keyword("CASE");
      print Q(<<"EOF");
#   $args{except} [[
EOF

      # do initialization of input variables
      $self->{thisdone} = 0;
      $self->{retvaldone} = 0;
      $self->{deferred} = "";
      %arg_list = ();
      $self->{gotRETVAL} = 0;

      INPUT_handler();
      process_keyword("INPUT|PREINIT|INTERFACE_MACRO|C_ARGS|ALIAS|ATTRS|PROTOTYPE|SCOPE|OVERLOAD");

      print Q(<<"EOF") if $self->{ScopeThisXSUB};
#   ENTER;
#   [[
EOF

      if (!$self->{thisdone} && defined($class)) {
        if (defined($static) or $func_name eq 'new') {
          print "\tchar *";
          $var_types{"CLASS"} = "char *";
          generate_init( {
            type          => "char *",
            num           => 1,
            var           => "CLASS",
            printed_name  => undef,
          } );
        }
        else {
          print "\t$class *";
          $var_types{"THIS"} = "$class *";
          generate_init( {
            type          => "$class *",
            num           => 1,
            var           => "THIS",
            printed_name  => undef,
          } );
        }
      }

      # do code
      if (/^\s*NOT_IMPLEMENTED_YET/) {
        print "\n\tPerl_croak(aTHX_ \"$pname: not implemented yet\");\n";
        $_ = '';
      }
      else {
        if ($self->{ret_type} ne "void") {
          print "\t" . &map_type($self->{ret_type}, 'RETVAL', $self->{hiertype}) . ";\n"
            if !$self->{retvaldone};
          $args_match{"RETVAL"} = 0;
          $var_types{"RETVAL"} = $self->{ret_type};
          print "\tdXSTARG;\n"
            if $args{optimize} and $targetable{$type_kind{$self->{ret_type}}};
        }

        if (@fake_INPUT or @fake_INPUT_pre) {
          unshift @line, @fake_INPUT_pre, @fake_INPUT, $_;
          $_ = "";
          $self->{processing_arg_with_types} = 1;
          INPUT_handler();
        }
        print $self->{deferred};

        process_keyword("INIT|ALIAS|ATTRS|PROTOTYPE|INTERFACE_MACRO|INTERFACE|C_ARGS|OVERLOAD");

        if (check_keyword("PPCODE")) {
          print_section();
          death ("PPCODE must be last thing") if @line;
          print "\tLEAVE;\n" if $self->{ScopeThisXSUB};
          print "\tPUTBACK;\n\treturn;\n";
        }
        elsif (check_keyword("CODE")) {
          print_section();
        }
        elsif (defined($class) and $func_name eq "DESTROY") {
          print "\n\t";
          print "delete THIS;\n";
        }
        else {
          print "\n\t";
          if ($self->{ret_type} ne "void") {
            print "RETVAL = ";
            $wantRETVAL = 1;
          }
          if (defined($static)) {
            if ($func_name eq 'new') {
              $func_name = "$class";
            }
            else {
              print "${class}::";
            }
          }
          elsif (defined($class)) {
            if ($func_name eq 'new') {
              $func_name .= " $class";
            }
            else {
              print "THIS->";
            }
          }
          $func_name =~ s/^\Q$args{'s'}//
            if exists $args{'s'};
          $func_name = 'XSFUNCTION' if $self->{interface};
          print "$func_name($self->{func_args});\n";
        }
      }

      # do output variables
      $self->{gotRETVAL} = 0;        # 1 if RETVAL seen in OUTPUT section;
      undef $self->{RETVAL_code} ;    # code to set RETVAL (from OUTPUT section);
      # $wantRETVAL set if 'RETVAL =' autogenerated
      ($wantRETVAL, $self->{ret_type}) = (0, 'void') if $RETVAL_no_return;
      undef %outargs;
      process_keyword("POSTCALL|OUTPUT|ALIAS|ATTRS|PROTOTYPE|OVERLOAD");

      generate_output( {
        type        => $var_types{$_},
        num         => $args_match{$_},
        var         => $_,
        do_setmagic => $DoSetMagic,
        do_push     => undef,
      } ) for grep $in_out{$_} =~ /OUT$/, keys %in_out;

      # all OUTPUT done, so now push the return value on the stack
      if ($self->{gotRETVAL} && $self->{RETVAL_code}) {
        print "\t$self->{RETVAL_code}\n";
      }
      elsif ($self->{gotRETVAL} || $wantRETVAL) {
        my $t = $args{optimize} && $targetable{$type_kind{$self->{ret_type}}};
        # Although the '$var' declared in the next line is never explicitly
        # used within this 'elsif' block, commenting it out leads to
        # disaster, starting with the first 'eval qq' inside the 'elsif' block
        # below.
        # It appears that this is related to the fact that at this point the
        # value of $t is a reference to an array whose [2] element includes
        # '$var' as a substring:
        # <i> <> <(IV)$var>
        my $var = 'RETVAL';
        my $type = $self->{ret_type};
    
        # 0: type, 1: with_size, 2: how, 3: how_size
        if ($t and not $t->[1] and $t->[0] eq 'p') {
          # PUSHp corresponds to setpvn.  Treate setpv directly
          my $what = eval qq("$t->[2]");
          warn $@ if $@;
    
          print "\tsv_setpv(TARG, $what); XSprePUSH; PUSHTARG;\n";
          $prepush_done = 1;
        }
        elsif ($t) {
          my $what = eval qq("$t->[2]");
          warn $@ if $@;
    
          my $tsize = $t->[3];
          $tsize = '' unless defined $tsize;
          $tsize = eval qq("$tsize");
          warn $@ if $@;
          print "\tXSprePUSH; PUSH$t->[0]($what$tsize);\n";
          $prepush_done = 1;
        }
        else {
          # RETVAL almost never needs SvSETMAGIC()
          generate_output( {
            type        => $self->{ret_type},
            num         => 0,
            var         => 'RETVAL',
            do_setmagic => 0,
            do_push     => undef,
          } );
        }
      }

      $xsreturn = 1 if $self->{ret_type} ne "void";
      my $num = $xsreturn;
      my $c = @outlist;
      print "\tXSprePUSH;" if $c and not $prepush_done;
      print "\tEXTEND(SP,$c);\n" if $c;
      $xsreturn += $c;
      generate_output( {
        type        => $var_types{$_},
        num         => $num++,
        var         => $_,
        do_setmagic => 0,
        do_push     => 1,
      } ) for @outlist;

      # do cleanup
      process_keyword("CLEANUP|ALIAS|ATTRS|PROTOTYPE|OVERLOAD");

      print Q(<<"EOF") if $self->{ScopeThisXSUB};
#   ]]
EOF
      print Q(<<"EOF") if $self->{ScopeThisXSUB} and not $PPCODE;
#   LEAVE;
EOF

      # print function trailer
      print Q(<<"EOF");
#    ]]
EOF
      print Q(<<"EOF") if $args{except};
#    BEGHANDLERS
#    CATCHALL
#    sprintf(errbuf, "%s: %s\\tpropagated", Xname, Xreason);
#    ENDHANDLERS
EOF
      if (check_keyword("CASE")) {
        blurt ("Error: No `CASE:' at top of function")
          unless $condnum;
        $_ = "CASE: $_";    # Restore CASE: label
        next;
      }
      last if $_ eq "$END:";
      death(/^$self->{BLOCK_re}/o ? "Misplaced `$1:'" : "Junk at end of function ($_)");
    }

    print Q(<<"EOF") if $args{except};
#    if (errbuf[0])
#    Perl_croak(aTHX_ errbuf);
EOF

    if ($xsreturn) {
      print Q(<<"EOF") unless $PPCODE;
#    XSRETURN($xsreturn);
EOF
    }
    else {
      print Q(<<"EOF") unless $PPCODE;
#    XSRETURN_EMPTY;
EOF
    }

    print Q(<<"EOF");
#]]
#
EOF

    $newXS = "newXS";
    $proto = "";

    # Build the prototype string for the xsub
    if ($self->{ProtoThisXSUB}) {
      $newXS = "newXSproto_portable";

      if ($self->{ProtoThisXSUB} eq 2) {
        # User has specified empty prototype
      }
      elsif ($self->{ProtoThisXSUB} eq 1) {
        my $s = ';';
        if ($min_args < $num_args)  {
          $s = '';
          $proto_arg[$min_args] .= ";";
        }
        push @proto_arg, "$s\@"
          if $ellipsis;
    
        $proto = join ("", grep defined, @proto_arg);
      }
      else {
        # User has specified a prototype
        $proto = $self->{ProtoThisXSUB};
      }
      $proto = qq{, "$proto"};
    }

    if (%XsubAliases) {
      $XsubAliases{$pname} = 0
        unless defined $XsubAliases{$pname};
      while ( my ($xname, $value) = each %XsubAliases) {
        push(@InitFileCode, Q(<<"EOF"));
#        cv = ${newXS}(\"$xname\", XS_$Full_func_name, file$proto);
#        XSANY.any_i32 = $value;
EOF
      }
    }
    elsif (@Attributes) {
      push(@InitFileCode, Q(<<"EOF"));
#        cv = ${newXS}(\"$pname\", XS_$Full_func_name, file$proto);
#        apply_attrs_string("$Package", cv, "@Attributes", 0);
EOF
    }
    elsif ($self->{interface}) {
      while ( my ($yname, $value) = each %Interfaces) {
        $yname = "$Package\::$yname" unless $yname =~ /::/;
        push(@InitFileCode, Q(<<"EOF"));
#        cv = ${newXS}(\"$yname\", XS_$Full_func_name, file$proto);
#        $self->{interface_macro_set}(cv,$value);
EOF
      }
    }
    elsif($newXS eq 'newXS'){ # work around P5NCI's empty newXS macro
      push(@InitFileCode,
       "        ${newXS}(\"$pname\", XS_$Full_func_name, file$proto);\n");
    }
    else {
      push(@InitFileCode,
       "        (void)${newXS}(\"$pname\", XS_$Full_func_name, file$proto);\n");
    }
  } # END 'PARAGRAPH' 'while' loop

  if ($self->{Overload}) { # make it findable with fetchmethod
    print Q(<<"EOF");
#XS(XS_${Packid}_nil); /* prototype to pass -Wmissing-prototypes */
#XS(XS_${Packid}_nil)
#{
#   dXSARGS;
#   XSRETURN_EMPTY;
#}
#
EOF
    unshift(@InitFileCode, <<"MAKE_FETCHMETHOD_WORK");
    /* Making a sub named "${Package}::()" allows the package */
    /* to be findable via fetchmethod(), and causes */
    /* overload::Overloaded("${Package}") to return true. */
    (void)${newXS}("${Package}::()", XS_${Packid}_nil, file$proto);
MAKE_FETCHMETHOD_WORK
  }

  # print initialization routine

  print Q(<<"EOF");
##ifdef __cplusplus
#extern "C"
##endif
EOF

  print Q(<<"EOF");
#XS(boot_$Module_cname); /* prototype to pass -Wmissing-prototypes */
#XS(boot_$Module_cname)
EOF

  print Q(<<"EOF");
#[[
##ifdef dVAR
#    dVAR; dXSARGS;
##else
#    dXSARGS;
##endif
EOF

  #Under 5.8.x and lower, newXS is declared in proto.h as expecting a non-const
  #file name argument. If the wrong qualifier is used, it causes breakage with
  #C++ compilers and warnings with recent gcc.
  #-Wall: if there is no $Full_func_name there are no xsubs in this .xs
  #so `file' is unused
  print Q(<<"EOF") if $Full_func_name;
##if (PERL_REVISION == 5 && PERL_VERSION < 9)
#    char* file = __FILE__;
##else
#    const char* file = __FILE__;
##endif
EOF

  print Q("#\n");

  print Q(<<"EOF");
#    PERL_UNUSED_VAR(cv); /* -W */
#    PERL_UNUSED_VAR(items); /* -W */
EOF

  print Q(<<"EOF") if $self->{WantVersionChk};
#    XS_VERSION_BOOTCHECK;
#
EOF

  print Q(<<"EOF") if defined $XsubAliases or defined $Interfaces;
#    {
#        CV * cv;
#
EOF

  print Q(<<"EOF") if ($self->{Overload});
#    /* register the overloading (type 'A') magic */
#    PL_amagic_generation++;
#    /* The magic for overload gets a GV* via gv_fetchmeth as */
#    /* mentioned above, and looks in the SV* slot of it for */
#    /* the "fallback" status. */
#    sv_setsv(
#        get_sv( "${Package}::()", TRUE ),
#        $self->{Fallback}
#    );
EOF

  print @InitFileCode;

  print Q(<<"EOF") if defined $XsubAliases or defined $Interfaces;
#    }
EOF

  if (@BootCode) {
    print "\n    /* Initialisation Section */\n\n";
    @line = @BootCode;
    print_section();
    print "\n    /* End of Initialisation Section */\n\n";
  }

  print Q(<<'EOF');
##if (PERL_REVISION == 5 && PERL_VERSION >= 9)
#  if (PL_unitcheckav)
#       call_list(PL_scopestack_ix, PL_unitcheckav);
##endif
EOF

  print Q(<<"EOF");
#    XSRETURN_YES;
#]]
#
EOF

  warn("Please specify prototyping behavior for $self->{filename} (see perlxs manual)\n")
    unless $self->{ProtoUsed};

  chdir($orig_cwd);
  select($orig_fh);
  untie *PSEUDO_STDOUT if tied *PSEUDO_STDOUT;
  close $FH;

  return 1;
}

sub report_error_count { $self->{errors} }

# Input:  ($_, @line) == unparsed input.
# Output: ($_, @line) == (rest of line, following lines).
# Return: the matched keyword if found, otherwise 0
sub check_keyword {
  $_ = shift(@line) while !/\S/ && @line;
  s/^(\s*)($_[0])\s*:\s*(?:#.*)?/$1/s && $2;
}

sub print_section {
  # the "do" is required for right semantics
  do { $_ = shift(@line) } while !/\S/ && @line;

  print("#line ", $line_no[@line_no - @line -1], " \"$self->{filepathname}\"\n")
    if $self->{WantLineNumbers} && !/^\s*#\s*line\b/ && !/^#if XSubPPtmp/;
  for (;  defined($_) && !/^$self->{BLOCK_re}/o;  $_ = shift(@line)) {
    print "$_\n";
  }
  print 'ExtUtils::ParseXS::CountLines'->end_marker, "\n" if $self->{WantLineNumbers};
}

sub merge_section {
  my $in = '';

  while (!/\S/ && @line) {
    $_ = shift(@line);
  }

  for (;  defined($_) && !/^$self->{BLOCK_re}/o;  $_ = shift(@line)) {
    $in .= "$_\n";
  }
  chomp $in;
  return $in;
}

sub process_keyword($) {
  my($pattern) = @_;
  my $kwd;

  no strict 'refs';
  &{"${kwd}_handler"}()
    while $kwd = check_keyword($pattern);
  use strict 'refs';
}

sub CASE_handler {
  blurt ("Error: `CASE:' after unconditional `CASE:'")
    if $condnum && $cond eq '';
  $cond = $_;
  trim_whitespace($cond);
  print "   ", ($condnum++ ? " else" : ""), ($cond ? " if ($cond)\n" : "\n");
  $_ = '';
}

sub INPUT_handler {
  for (;  !/^$self->{BLOCK_re}/o;  $_ = shift(@line)) {
    last if /^\s*NOT_IMPLEMENTED_YET/;
    next unless /\S/;        # skip blank lines

    trim_whitespace($_);
    my $ln = $_;

    # remove trailing semicolon if no initialisation
    s/\s*;$//g unless /[=;+].*\S/;

    # Process the length(foo) declarations
    if (s/^([^=]*)\blength\(\s*(\w+)\s*\)\s*$/$1 XSauto_length_of_$2=NO_INIT/x) {
      print "\tSTRLEN\tSTRLEN_length_of_$2;\n";
      $lengthof{$2} = undef;
      $self->{deferred} .= "\n\tXSauto_length_of_$2 = STRLEN_length_of_$2;\n";
    }

    # check for optional initialisation code
    my $var_init = '';
    $var_init = $1 if s/\s*([=;+].*)$//s;
    $var_init =~ s/"/\\"/g;

    s/\s+/ /g;
    my ($var_type, $var_addr, $var_name) = /^(.*?[^&\s])\s*(\&?)\s*\b(\w+)$/s
      or blurt("Error: invalid argument declaration '$ln'"), next;

    # Check for duplicate definitions
    blurt ("Error: duplicate definition of argument '$var_name' ignored"), next
      if $arg_list{$var_name}++
    or defined $argtype_seen{$var_name} and not $self->{processing_arg_with_types};

    $self->{thisdone} |= $var_name eq "THIS";
    $self->{retvaldone} |= $var_name eq "RETVAL";
    $var_types{$var_name} = $var_type;
    # XXXX This check is a safeguard against the unfinished conversion of
    # generate_init().  When generate_init() is fixed,
    # one can use 2-args map_type() unconditionally.
    my $printed_name;
    if ($var_type =~ / \( \s* \* \s* \) /x) {
      # Function pointers are not yet supported with &output_init!
      print "\t" . &map_type($var_type, $var_name, $self->{hiertype});
      $printed_name = 1;
    }
    else {
      print "\t" . &map_type($var_type, undef, $self->{hiertype});
      $printed_name = 0;
    }
    $var_num = $args_match{$var_name};

    if ($var_num) {
      $proto_arg[$var_num] = $proto_letter{$var_type} || "\$";
    }
    $self->{func_args} =~ s/\b($var_name)\b/&$1/ if $var_addr;
    if ($var_init =~ /^[=;]\s*NO_INIT\s*;?\s*$/
      or $in_out{$var_name} and $in_out{$var_name} =~ /^OUT/
      and $var_init !~ /\S/) {
      if ($printed_name) {
        print ";\n";
      }
      else {
        print "\t$var_name;\n";
      }
    }
    elsif ($var_init =~ /\S/) {
      output_init( {
        type          => $var_type,
        num           => $var_num,
        var           => $var_name,
        init          => $var_init,
        printed_name  => $printed_name,
      } );
    }
    elsif ($var_num) {
      generate_init( {
        type          => $var_type,
        num           => $var_num,
        var           => $var_name,
        printed_name  => $printed_name,
      } );
    }
    else {
      print ";\n";
    }
  }
}

sub OUTPUT_handler {
  for (;  !/^$self->{BLOCK_re}/o;  $_ = shift(@line)) {
    next unless /\S/;
    if (/^\s*SETMAGIC\s*:\s*(ENABLE|DISABLE)\s*/) {
      $DoSetMagic = ($1 eq "ENABLE" ? 1 : 0);
      next;
    }
    my ($outarg, $outcode) = /^\s*(\S+)\s*(.*?)\s*$/s;
    blurt ("Error: duplicate OUTPUT argument '$outarg' ignored"), next
      if $outargs{$outarg}++;
    if (!$self->{gotRETVAL} and $outarg eq 'RETVAL') {
      # deal with RETVAL last
      $self->{RETVAL_code} = $outcode;
      $self->{gotRETVAL} = 1;
      next;
    }
    blurt ("Error: OUTPUT $outarg not an argument"), next
      unless defined($args_match{$outarg});
    blurt("Error: No input definition for OUTPUT argument '$outarg' - ignored"), next
      unless defined $var_types{$outarg};
    $var_num = $args_match{$outarg};
    if ($outcode) {
      print "\t$outcode\n";
      print "\tSvSETMAGIC(ST(" , $var_num-1 , "));\n" if $DoSetMagic;
    }
    else {
      generate_output( {
        type        => $var_types{$outarg},
        num         => $var_num,
        var         => $outarg,
        do_setmagic => $DoSetMagic,
        do_push     => undef,
      } );
    }
    delete $in_out{$outarg}     # No need to auto-OUTPUT
      if exists $in_out{$outarg} and $in_out{$outarg} =~ /OUT$/;
  }
}

sub C_ARGS_handler() {
  my $in = merge_section();

  trim_whitespace($in);
  $self->{func_args} = $in;
}

sub INTERFACE_MACRO_handler() {
  my $in = merge_section();

  trim_whitespace($in);
  if ($in =~ /\s/) {        # two
    ($self->{interface_macro}, $self->{interface_macro_set}) = split ' ', $in;
  }
  else {
    $self->{interface_macro} = $in;
    $self->{interface_macro_set} = 'UNKNOWN_CVT'; # catch later
  }
  $self->{interface} = 1;        # local
  $Interfaces = 1;        # global
}

sub INTERFACE_handler() {
  my $in = merge_section();

  trim_whitespace($in);

  foreach (split /[\s,]+/, $in) {
    my $iface_name = $_;
    $iface_name =~ s/^$self->{Prefix}//;
    $Interfaces{$iface_name} = $_;
  }
  print Q(<<"EOF");
#    XSFUNCTION = $self->{interface_macro}($self->{ret_type},cv,XSANY.any_dptr);
EOF
  $self->{interface} = 1;        # local
  $Interfaces = 1;        # global
}

sub CLEANUP_handler() { print_section() }
sub PREINIT_handler() { print_section() }
sub POSTCALL_handler() { print_section() }
sub INIT_handler()    { print_section() }

sub GetAliases {
  my ($line) = @_;
  my ($orig) = $line;

  # Parse alias definitions
  # format is
  #    alias = value alias = value ...

  while ($line =~ s/^\s*([\w:]+)\s*=\s*(\w+)\s*//) {
    my ($alias, $value) = ($1, $2);
    my $orig_alias = $alias;

    # check for optional package definition in the alias
    $alias = $self->{Packprefix} . $alias if $alias !~ /::/;

    # check for duplicate alias name & duplicate value
    Warn("Warning: Ignoring duplicate alias '$orig_alias'")
      if defined $XsubAliases{$alias};

    Warn("Warning: Aliases '$orig_alias' and '$XsubAliasValues{$value}' have identical values")
      if $XsubAliasValues{$value};

    $XsubAliases = 1;
    $XsubAliases{$alias} = $value;
    $XsubAliasValues{$value} = $orig_alias;
  }

  blurt("Error: Cannot parse ALIAS definitions from '$orig'")
    if $line;
}

sub ATTRS_handler () {
  for (;  !/^$self->{BLOCK_re}/o;  $_ = shift(@line)) {
    next unless /\S/;
    trim_whitespace($_);
    push @Attributes, $_;
  }
}

sub ALIAS_handler () {
  for (;  !/^$self->{BLOCK_re}/o;  $_ = shift(@line)) {
    next unless /\S/;
    trim_whitespace($_);
    GetAliases($_) if $_;
  }
}

sub OVERLOAD_handler() {
  for (;  !/^$self->{BLOCK_re}/o;  $_ = shift(@line)) {
    next unless /\S/;
    trim_whitespace($_);
    while ( s/^\s*([\w:"\\)\+\-\*\/\%\<\>\.\&\|\^\!\~\{\}\=]+)\s*//) {
      $self->{Overload} = 1 unless $self->{Overload};
      my $overload = "$Package\::(".$1;
      push(@InitFileCode,
       "        (void)${newXS}(\"$overload\", XS_$Full_func_name, file$proto);\n");
    }
  }
}

sub FALLBACK_handler() {
  # the rest of the current line should contain either TRUE,
  # FALSE or UNDEF

  trim_whitespace($_);
  my %map = (
    TRUE => "&PL_sv_yes", 1 => "&PL_sv_yes",
    FALSE => "&PL_sv_no", 0 => "&PL_sv_no",
    UNDEF => "&PL_sv_undef",
  );

  # check for valid FALLBACK value
  death ("Error: FALLBACK: TRUE/FALSE/UNDEF") unless exists $map{uc $_};

  $self->{Fallback} = $map{uc $_};
}


sub REQUIRE_handler () {
  # the rest of the current line should contain a version number
  my ($Ver) = $_;

  trim_whitespace($Ver);

  death ("Error: REQUIRE expects a version number")
    unless $Ver;

  # check that the version number is of the form n.n
  death ("Error: REQUIRE: expected a number, got '$Ver'")
    unless $Ver =~ /^\d+(\.\d*)?/;

  death ("Error: xsubpp $Ver (or better) required--this is only $VERSION.")
    unless $VERSION >= $Ver;
}

sub VERSIONCHECK_handler () {
  # the rest of the current line should contain either ENABLE or
  # DISABLE

  trim_whitespace($_);

  # check for ENABLE/DISABLE
  death ("Error: VERSIONCHECK: ENABLE/DISABLE")
    unless /^(ENABLE|DISABLE)/i;

  $self->{WantVersionChk} = 1 if $1 eq 'ENABLE';
  $self->{WantVersionChk} = 0 if $1 eq 'DISABLE';

}

sub PROTOTYPE_handler () {
  my $specified;

  death("Error: Only 1 PROTOTYPE definition allowed per xsub")
    if $self->{proto_in_this_xsub}++;

  for (;  !/^$self->{BLOCK_re}/o;  $_ = shift(@line)) {
    next unless /\S/;
    $specified = 1;
    trim_whitespace($_);
    if ($_ eq 'DISABLE') {
      $self->{ProtoThisXSUB} = 0;
    }
    elsif ($_ eq 'ENABLE') {
      $self->{ProtoThisXSUB} = 1;
    }
    else {
      # remove any whitespace
      s/\s+//g;
      death("Error: Invalid prototype '$_'")
        unless valid_proto_string($_);
      $self->{ProtoThisXSUB} = C_string($_);
    }
  }

  # If no prototype specified, then assume empty prototype ""
  $self->{ProtoThisXSUB} = 2 unless $specified;

  $self->{ProtoUsed} = 1;
}

sub SCOPE_handler () {
  death("Error: Only 1 SCOPE declaration allowed per xsub")
    if $self->{scope_in_this_xsub}++;

  trim_whitespace($_);
  death ("Error: SCOPE: ENABLE/DISABLE")
      unless /^(ENABLE|DISABLE)\b/i;
  $self->{ScopeThisXSUB} = ( uc($1) eq 'ENABLE' );
}

sub PROTOTYPES_handler () {
  # the rest of the current line should contain either ENABLE or
  # DISABLE

  trim_whitespace($_);

  # check for ENABLE/DISABLE
  death ("Error: PROTOTYPES: ENABLE/DISABLE")
    unless /^(ENABLE|DISABLE)/i;

  $self->{WantPrototypes} = 1 if $1 eq 'ENABLE';
  $self->{WantPrototypes} = 0 if $1 eq 'DISABLE';
  $self->{ProtoUsed} = 1;

}

sub PushXSStack {
  my %args = @_;
  # Save the current file context.
  push(@XSStack, {
          type            => 'file',
          LastLine        => $self->{lastline},
          LastLineNo      => $self->{lastline_no},
          Line            => \@line,
          LineNo          => \@line_no,
          Filename        => $self->{filename},
          Filepathname    => $self->{filepathname},
          Handle          => $FH,
          IsPipe          => scalar($self->{filename} =~ /\|\s*$/),
          %args,
         });

}

sub INCLUDE_handler () {
  # the rest of the current line should contain a valid filename

  trim_whitespace($_);

  death("INCLUDE: filename missing")
    unless $_;

  death("INCLUDE: output pipe is illegal")
    if /^\s*\|/;

  # simple minded recursion detector
  death("INCLUDE loop detected")
    if $IncludedFiles{$_};

  ++$IncludedFiles{$_} unless /\|\s*$/;

  if (/\|\s*$/ && /^\s*perl\s/) {
    Warn("The INCLUDE directive with a command is discouraged." .
         " Use INCLUDE_COMMAND instead! In particular using 'perl'" .
         " in an 'INCLUDE: ... |' directive is not guaranteed to pick" .
         " up the correct perl. The INCLUDE_COMMAND directive allows" .
         " the use of \$^X as the currently running perl, see" .
         " 'perldoc perlxs' for details.");
  }

  PushXSStack();

  $FH = Symbol::gensym();

  # open the new file
  open ($FH, "$_") or death("Cannot open '$_': $!");

  print Q(<<"EOF");
#
#/* INCLUDE:  Including '$_' from '$self->{filename}' */
#
EOF

  $self->{filename} = $_;
  $self->{filepathname} = File::Spec->catfile($self->{dir}, $self->{filename});

  # Prime the pump by reading the first
  # non-blank line

  # skip leading blank lines
  while (<$FH>) {
    last unless /^\s*$/;
  }

  $self->{lastline} = $_;
  $self->{lastline_no} = $.;
}

sub QuoteArgs {
  my $cmd = shift;
  my @args = split /\s+/, $cmd;
  $cmd = shift @args;
  for (@args) {
    $_ = q(").$_.q(") if !/^\"/ && length($_) > 0;
  }
  return join (' ', ($cmd, @args));
}

sub INCLUDE_COMMAND_handler () {
  # the rest of the current line should contain a valid command

  trim_whitespace($_);

  $_ = QuoteArgs($_) if $^O eq 'VMS';

  death("INCLUDE_COMMAND: command missing")
    unless $_;

  death("INCLUDE_COMMAND: pipes are illegal")
    if /^\s*\|/ or /\|\s*$/;

  PushXSStack( IsPipe => 1 );

  $FH = Symbol::gensym();

  # If $^X is used in INCLUDE_COMMAND, we know it's supposed to be
  # the same perl interpreter as we're currently running
  s/^\s*\$\^X/$^X/;

  # open the new file
  open ($FH, "-|", "$_")
    or death("Cannot run command '$_' to include its output: $!");

  print Q(<<"EOF");
#
#/* INCLUDE_COMMAND:  Including output of '$_' from '$self->{filename}' */
#
EOF

  $self->{filename} = $_;
  $self->{filepathname} = $self->{filename};
  $self->{filepathname} =~ s/\"/\\"/g;

  # Prime the pump by reading the first
  # non-blank line

  # skip leading blank lines
  while (<$FH>) {
    last unless /^\s*$/;
  }

  $self->{lastline} = $_;
  $self->{lastline_no} = $.;
}

sub PopFile() {
  return 0 unless $XSStack[-1]{type} eq 'file';

  my $data     = pop @XSStack;
  my $ThisFile = $self->{filename};
  my $isPipe   = $data->{IsPipe};

  --$IncludedFiles{$self->{filename}}
    unless $isPipe;

  close $FH;

  $FH         = $data->{Handle};
  # $filename is the leafname, which for some reason isused for diagnostic
  # messages, whereas $filepathname is the full pathname, and is used for
  # #line directives.
  $self->{filename}   = $data->{Filename};
  $self->{filepathname} = $data->{Filepathname};
  $self->{lastline}   = $data->{LastLine};
  $self->{lastline_no} = $data->{LastLineNo};
  @line       = @{ $data->{Line} };
  @line_no    = @{ $data->{LineNo} };

  if ($isPipe and $? ) {
    --$self->{lastline_no};
    print STDERR "Error reading from pipe '$ThisFile': $! in $self->{filename}, line $self->{lastline_no}\n" ;
    exit 1;
  }

  print Q(<<"EOF");
#
#/* INCLUDE: Returning to '$self->{filename}' from '$ThisFile' */
#
EOF

  return 1;
}

sub check_cpp {
  my @cpp = grep(/^\#\s*(?:if|e\w+)/, @line);
  if (@cpp) {
    my ($cpp, $cpplevel);
    for $cpp (@cpp) {
      if ($cpp =~ /^\#\s*if/) {
        $cpplevel++;
      }
      elsif (!$cpplevel) {
        Warn("Warning: #else/elif/endif without #if in this function");
        print STDERR "    (precede it with a blank line if the matching #if is outside the function)\n"
          if $XSStack[-1]{type} eq 'if';
        return;
      }
      elsif ($cpp =~ /^\#\s*endif/) {
        $cpplevel--;
      }
    }
    Warn("Warning: #if without #endif in this function") if $cpplevel;
  }
}


sub Q {
  my($text) = @_;
  $text =~ s/^#//gm;
  $text =~ s/\[\[/{/g;
  $text =~ s/\]\]/}/g;
  $text;
}

# Read next xsub into @line from ($lastline, <$FH>).
sub fetch_para {
  # parse paragraph
  death ("Error: Unterminated `#if/#ifdef/#ifndef'")
    if !defined $self->{lastline} && $XSStack[-1]{type} eq 'if';
  @line = ();
  @line_no = ();
  return PopFile() if !defined $self->{lastline};

  if ($self->{lastline} =~
      /^MODULE\s*=\s*([\w:]+)(?:\s+PACKAGE\s*=\s*([\w:]+))?(?:\s+PREFIX\s*=\s*(\S+))?\s*$/) {
    my $Module = $1;
    $Package = defined($2) ? $2 : ''; # keep -w happy
    $self->{Prefix}  = defined($3) ? $3 : ''; # keep -w happy
    $self->{Prefix} = quotemeta $self->{Prefix};
    ($Module_cname = $Module) =~ s/\W/_/g;
    ($Packid = $Package) =~ tr/:/_/;
    $self->{Packprefix} = $Package;
    $self->{Packprefix} .= "::" if $self->{Packprefix} ne "";
    $self->{lastline} = "";
  }

  for (;;) {
    # Skip embedded PODs
    while ($self->{lastline} =~ /^=/) {
      while ($self->{lastline} = <$FH>) {
        last if ($self->{lastline} =~ /^=cut\s*$/);
      }
      death ("Error: Unterminated pod") unless $self->{lastline};
      $self->{lastline} = <$FH>;
      chomp $self->{lastline};
      $self->{lastline} =~ s/^\s+$//;
    }
    if ($self->{lastline} !~ /^\s*#/ ||
    # CPP directives:
    #    ANSI:    if ifdef ifndef elif else endif define undef
    #        line error pragma
    #    gcc:    warning include_next
    #   obj-c:    import
    #   others:    ident (gcc notes that some cpps have this one)
    $self->{lastline} =~ /^#[ \t]*(?:(?:if|ifn?def|elif|else|endif|define|undef|pragma|error|warning|line\s+\d+|ident)\b|(?:include(?:_next)?|import)\s*["<].*[>"])/) {
      last if $self->{lastline} =~ /^\S/ && @line && $line[-1] eq "";
      push(@line, $self->{lastline});
      push(@line_no, $self->{lastline_no});
    }

    # Read next line and continuation lines
    last unless defined($self->{lastline} = <$FH>);
    $self->{lastline_no} = $.;
    my $tmp_line;
    $self->{lastline} .= $tmp_line
      while ($self->{lastline} =~ /\\$/ && defined($tmp_line = <$FH>));

    chomp $self->{lastline};
    $self->{lastline} =~ s/^\s+$//;
  }
  pop(@line), pop(@line_no) while @line && $line[-1] eq "";
  1;
}

sub output_init {
  my $argsref = shift;
  my ($type, $num, $var, $init, $printed_name) = (
    $argsref->{type},
    $argsref->{num},
    $argsref->{var},
    $argsref->{init},
    $argsref->{printed_name}
  );
  my $arg = "ST(" . ($num - 1) . ")";

  if (  $init =~ /^=/  ) {
    if ($printed_name) {
      eval qq/print " $init\\n"/;
    }
    else {
      eval qq/print "\\t$var $init\\n"/;
    }
    warn $@ if $@;
  }
  else {
    if (  $init =~ s/^\+//  &&  $num  ) {
      generate_init( {
        type          => $type,
        num           => $num,
        var           => $var,
        printed_name  => $printed_name,
      } );
    }
    elsif ($printed_name) {
      print ";\n";
      $init =~ s/^;//;
    }
    else {
      eval qq/print "\\t$var;\\n"/;
      warn $@ if $@;
      $init =~ s/^;//;
    }
    $self->{deferred} .= eval qq/"\\n\\t$init\\n"/;
    warn $@ if $@;
  }
}

sub generate_init {
  my $argsref = shift;
  my ($type, $num, $var, $printed_name) = (
    $argsref->{type},
    $argsref->{num},
    $argsref->{var},
    $argsref->{printed_name},
  );
  my $arg = "ST(" . ($num - 1) . ")";
  my ($argoff, $ntype, $tk);
  $argoff = $num - 1;

  $type = tidy_type($type);
  blurt("Error: '$type' not in typemap"), return
    unless defined($type_kind{$type});

  ($ntype = $type) =~ s/\s*\*/Ptr/g;
  my $subtype;
  ($subtype = $ntype) =~ s/(?:Array)?(?:Ptr)?$//;
  $tk = $type_kind{$type};
  $tk =~ s/OBJ$/REF/ if $func_name =~ /DESTROY$/;
  if ($tk eq 'T_PV' and exists $lengthof{$var}) {
    print "\t$var" unless $printed_name;
    print " = ($type)SvPV($arg, STRLEN_length_of_$var);\n";
    die "default value not supported with length(NAME) supplied"
      if defined $defaults{$var};
    return;
  }
  $type =~ tr/:/_/ unless $self->{hiertype};
  blurt("Error: No INPUT definition for type '$type', typekind '$type_kind{$type}' found"), return
    unless defined $input_expr{$tk};
  my $expr = $input_expr{$tk};
  if ($expr =~ /DO_ARRAY_ELEM/) {
    blurt("Error: '$subtype' not in typemap"), return
      unless defined($type_kind{$subtype});
    blurt("Error: No INPUT definition for type '$subtype', typekind '$type_kind{$subtype}' found"), return
      unless defined $input_expr{$type_kind{$subtype}};
    my $subexpr = $input_expr{$type_kind{$subtype}};
    $subexpr =~ s/\$type/\$subtype/g;
    $subexpr =~ s/ntype/subtype/g;
    $subexpr =~ s/\$arg/ST(ix_$var)/g;
    $subexpr =~ s/\n\t/\n\t\t/g;
    $subexpr =~ s/is not of (.*\")/[arg %d] is not of $1, ix_$var + 1/g;
    $subexpr =~ s/\$var/${var}[ix_$var - $argoff]/;
    $expr =~ s/DO_ARRAY_ELEM/$subexpr/;
  }
  if ($expr =~ m#/\*.*scope.*\*/#i) {  # "scope" in C comments
    $self->{ScopeThisXSUB} = 1;
  }
  if (defined($defaults{$var})) {
    $expr =~ s/(\t+)/$1    /g;
    $expr =~ s/        /\t/g;
    if ($printed_name) {
      print ";\n";
    }
    else {
      eval qq/print "\\t$var;\\n"/;
      warn $@ if $@;
    }
    if ($defaults{$var} eq 'NO_INIT') {
      $self->{deferred} .= eval qq/"\\n\\tif (items >= $num) {\\n$expr;\\n\\t}\\n"/;
    }
    else {
      $self->{deferred} .= eval qq/"\\n\\tif (items < $num)\\n\\t    $var = $defaults{$var};\\n\\telse {\\n$expr;\\n\\t}\\n"/;
    }
    warn $@ if $@;
  }
  elsif ($self->{ScopeThisXSUB} or $expr !~ /^\s*\$var =/) {
    if ($printed_name) {
      print ";\n";
    }
    else {
      eval qq/print "\\t$var;\\n"/;
      warn $@ if $@;
    }
    $self->{deferred} .= eval qq/"\\n$expr;\\n"/;
    warn $@ if $@;
  }
  else {
    die "panic: do not know how to handle this branch for function pointers"
      if $printed_name;
    eval qq/print "$expr;\\n"/;
    warn $@ if $@;
  }
}

sub generate_output {
  my $argsref = shift;
  my ($type, $num, $var, $do_setmagic, $do_push) = (
    $argsref->{type},
    $argsref->{num},
    $argsref->{var},
    $argsref->{do_setmagic},
    $argsref->{do_push}
  );
  my $arg = "ST(" . ($num - ($num != 0)) . ")";
  my $ntype;

  $type = tidy_type($type);
  if ($type =~ /^array\(([^,]*),(.*)\)/) {
    print "\t$arg = sv_newmortal();\n";
    print "\tsv_setpvn($arg, (char *)$var, $2 * sizeof($1));\n";
    print "\tSvSETMAGIC($arg);\n" if $do_setmagic;
  }
  else {
    blurt("Error: '$type' not in typemap"), return
      unless defined($type_kind{$type});
    blurt("Error: No OUTPUT definition for type '$type', typekind '$type_kind{$type}' found"), return
      unless defined $output_expr{$type_kind{$type}};
    ($ntype = $type) =~ s/\s*\*/Ptr/g;
    $ntype =~ s/\(\)//g;
    my $subtype;
    ($subtype = $ntype) =~ s/(?:Array)?(?:Ptr)?$//;
    my $expr = $output_expr{$type_kind{$type}};
    if ($expr =~ /DO_ARRAY_ELEM/) {
      blurt("Error: '$subtype' not in typemap"), return
        unless defined($type_kind{$subtype});
      blurt("Error: No OUTPUT definition for type '$subtype', typekind '$type_kind{$subtype}' found"), return
        unless defined $output_expr{$type_kind{$subtype}};
      my $subexpr = $output_expr{$type_kind{$subtype}};
      $subexpr =~ s/ntype/subtype/g;
      $subexpr =~ s/\$arg/ST(ix_$var)/g;
      $subexpr =~ s/\$var/${var}[ix_$var]/g;
      $subexpr =~ s/\n\t/\n\t\t/g;
      $expr =~ s/DO_ARRAY_ELEM\n/$subexpr/;
      eval "print qq\a$expr\a";
      warn $@ if $@;
      print "\t\tSvSETMAGIC(ST(ix_$var));\n" if $do_setmagic;
    }
    elsif ($var eq 'RETVAL') {
      if ($expr =~ /^\t\$arg = new/) {
        # We expect that $arg has refcnt 1, so we need to
        # mortalize it.
        eval "print qq\a$expr\a";
        warn $@ if $@;
        print "\tsv_2mortal(ST($num));\n";
        print "\tSvSETMAGIC(ST($num));\n" if $do_setmagic;
      }
      elsif ($expr =~ /^\s*\$arg\s*=/) {
        # We expect that $arg has refcnt >=1, so we need
        # to mortalize it!
        eval "print qq\a$expr\a";
        warn $@ if $@;
        print "\tsv_2mortal(ST(0));\n";
        print "\tSvSETMAGIC(ST(0));\n" if $do_setmagic;
      }
      else {
        # Just hope that the entry would safely write it
        # over an already mortalized value. By
        # coincidence, something like $arg = &sv_undef
        # works too.
        print "\tST(0) = sv_newmortal();\n";
        eval "print qq\a$expr\a";
        warn $@ if $@;
        # new mortals don't have set magic
      }
    }
    elsif ($do_push) {
      print "\tPUSHs(sv_newmortal());\n";
      $arg = "ST($num)";
      eval "print qq\a$expr\a";
      warn $@ if $@;
      print "\tSvSETMAGIC($arg);\n" if $do_setmagic;
    }
    elsif ($arg =~ /^ST\(\d+\)$/) {
      eval "print qq\a$expr\a";
      warn $@ if $@;
      print "\tSvSETMAGIC($arg);\n" if $do_setmagic;
    }
  }
}

sub Warn {
  # work out the line number
  my $warn_line_number = $line_no[@line_no - @line -1];

  print STDERR "@_ in $self->{filename}, line $warn_line_number\n";
}

sub blurt {
  Warn @_;
  $self->{errors}++
}

sub death {
  Warn @_;
  exit 1;
}

1;
