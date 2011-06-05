package ExtUtils::ParseXS::Utilities;
use strict;
use warnings;
use Exporter;
use File::Spec;
use lib qw( lib );
use ExtUtils::ParseXS::Constants ();
our (@ISA, @EXPORT_OK);
@ISA = qw(Exporter);
@EXPORT_OK = qw(
  standard_typemap_locations
  trim_whitespace
  tidy_type
  C_string
  valid_proto_string
  process_typemaps
  process_single_typemap
  make_targetable
  map_type
  standard_XS_defs
  assign_func_args
  analyze_preprocessor_statements
  set_cond
  Warn
  blurt
  death
  check_conditional_preprocessor_statements
);

=head1 NAME

ExtUtils::ParseXS::Utilities - Subroutines used with ExtUtils::ParseXS

=head1 SYNOPSIS

  use ExtUtils::ParseXS::Utilities qw(
    standard_typemap_locations
    trim_whitespace
    tidy_type
    C_string
    valid_proto_string
    process_typemaps
    process_single_typemap
    make_targetable
    map_type
    standard_XS_defs
    assign_func_args
    analyze_preprocessor_statements
    set_cond
    Warn
    blurt
    death
    check_conditional_preprocessor_statements
  );

=head1 SUBROUTINES

The following functions are not considered to be part of the public interface.
They are documented here for the benefit of future maintainers of this module.

=head2 C<standard_typemap_locations()>

=over 4

=item * Purpose

Provide a list of filepaths where F<typemap> files may be found.  The
filepaths -- relative paths to files (not just directory paths) -- appear in this list in lowest-to-highest priority.

The highest priority is to look in the current directory.  

  'typemap'

The second and third highest priorities are to look in the parent of the
current directory and a directory called F<lib/ExtUtils> underneath the parent
directory.

  '../typemap',
  '../lib/ExtUtils/typemap',

The fourth through ninth highest priorities are to look in the corresponding
grandparent, great-grandparent and great-great-grandparent directories.

  '../../typemap',
  '../../lib/ExtUtils/typemap',
  '../../../typemap',
  '../../../lib/ExtUtils/typemap',
  '../../../../typemap',
  '../../../../lib/ExtUtils/typemap',

The tenth and subsequent priorities are to look in directories named
F<ExtUtils> which are subdirectories of directories found in C<@INC> --
I<provided> a file named F<typemap> actually exists in such a directory.
Example:

  '/usr/local/lib/perl5/5.10.1/ExtUtils/typemap',

However, these filepaths appear in the list returned by
C<standard_typemap_locations()> in reverse order, I<i.e.>, lowest-to-highest.

  '/usr/local/lib/perl5/5.10.1/ExtUtils/typemap',
  '../../../../lib/ExtUtils/typemap',
  '../../../../typemap',
  '../../../lib/ExtUtils/typemap',
  '../../../typemap',
  '../../lib/ExtUtils/typemap',
  '../../typemap',
  '../lib/ExtUtils/typemap',
  '../typemap',
  'typemap'

=item * Arguments

  my @stl = standard_typemap_locations( \@INC );

Reference to C<@INC>.

=item * Return Value

Array holding list of directories to be searched for F<typemap> files.

=back

=cut

sub standard_typemap_locations {
  my $include_ref = shift;
  my @tm = qw(typemap);

  my $updir = File::Spec->updir();
  foreach my $dir (
      File::Spec->catdir(($updir) x 1),
      File::Spec->catdir(($updir) x 2),
      File::Spec->catdir(($updir) x 3),
      File::Spec->catdir(($updir) x 4),
  ) {
    unshift @tm, File::Spec->catfile($dir, 'typemap');
    unshift @tm, File::Spec->catfile($dir, lib => ExtUtils => 'typemap');
  }
  foreach my $dir (@{ $include_ref}) {
    my $file = File::Spec->catfile($dir, ExtUtils => 'typemap');
    unshift @tm, $file if -e $file;
  }
  return @tm;
}

=head2 C<trim_whitespace()>

=over 4

=item * Purpose

Perform an in-place trimming of leading and trailing whitespace from the
first argument provided to the function.

=item * Argument

  trim_whitespace($arg);

=item * Return Value

None.  Remember:  this is an I<in-place> modification of the argument.

=back

=cut

sub trim_whitespace {
  $_[0] =~ s/^\s+|\s+$//go;
}

=head2 C<tidy_type()>

=over 4

=item * Purpose

Rationalize any asterisks (C<*>) by joining them into bunches, removing
interior whitespace, then trimming leading and trailing whitespace.

=item * Arguments

    ($ret_type) = tidy_type($_);

String to be cleaned up.

=item * Return Value

String cleaned up.

=back

=cut

sub tidy_type {
  local ($_) = @_;

  # rationalise any '*' by joining them into bunches and removing whitespace
  s#\s*(\*+)\s*#$1#g;
  s#(\*+)# $1 #g;

  # change multiple whitespace into a single space
  s/\s+/ /g;

  # trim leading & trailing whitespace
  trim_whitespace($_);

  $_;
}

=head2 C<C_string()>

=over 4

=item * Purpose

Escape backslashes (C<\>) in prototype strings.

=item * Arguments

      $ProtoThisXSUB = C_string($_);

String needing escaping.

=item * Return Value

Properly escaped string.

=back

=cut

sub C_string {
  my($string) = @_;

  $string =~ s[\\][\\\\]g;
  $string;
}

=head2 C<valid_proto_string()>

=over 4

=item * Purpose

Validate prototype string.

=item * Arguments

String needing checking.

=item * Return Value

Upon success, returns the same string passed as argument.

Upon failure, returns C<0>.

=back

=cut

sub valid_proto_string {
  my($string) = @_;

  if ( $string =~ /^$ExtUtils::ParseXS::Constants::proto_re+$/ ) {
    return $string;
  }

  return 0;
}

=head2 C<process_typemaps()>

=over 4

=item * Purpose

Process all typemap files.

=item * Arguments

  my ($type_kind_ref, $proto_letter_ref, $input_expr_ref, $output_expr_ref) =
    process_typemaps( $args{typemap}, $pwd );
      
List of two elements:  C<typemap> element from C<%args>; current working
directory.

=item * Return Value

Upon success, returns a list of four hash references.  (This will probably be
refactored.)  Here is a I<rough> description of what is in these hashrefs:

=over 4

=item * C<$type_kind_ref>

  {
    'char **' => 'T_PACKEDARRAY',
    'bool_t' => 'T_IV',
    'AV *' => 'T_AVREF',
    'InputStream' => 'T_IN',
    'double' => 'T_DOUBLE',
    # ...
  }

Keys:  C types.  Values:  Corresponding Perl types.

=item * C<$proto_letter_ref>

  {
    'char **' => '$',
    'bool_t' => '$',
    'AV *' => '$',
    'InputStream' => '$',
    'double' => '$',
    # ...
  }

Keys: C types.  Values. Corresponding prototype letters.

=item * C<$input_expr_ref>

  {
    'T_CALLBACK' => '	$var = make_perl_cb_$type($arg)
  ',
    'T_OUT' => '	$var = IoOFP(sv_2io($arg))
  ',
    'T_REF_IV_PTR' => '	if (sv_isa($arg, \\"${ntype}\\")) {
    # ...
  }

Keys:  Perl API calls B<CONFIRM!>.  Values:  Newline-terminated strings that
will be written to C source code (F<.c>) files.   The strings are C code, but
with Perl variables whose values will be interpolated at F<xsubpp>'s runtime
by one of the C<eval EXPR> statements in ExtUtils::ParseXS.

=item * C<$output_expr_ref>

  {
    'T_CALLBACK' => '	sv_setpvn($arg, $var.context.value().chp(),
  		$var.context.value().size());
  ',
    'T_OUT' => '	{
  	    GV *gv = newGVgen("$Package");
  	    if ( do_open(gv, "+>&", 3, FALSE, 0, 0, $var) )
  		sv_setsv($arg, sv_bless(newRV((SV*)gv), gv_stashpv("$Package",1)));
  	    else
  		$arg = &PL_sv_undef;
  	}
  ',
    # ...
  }

Keys:  Perl API calls B<CONFIRM!>.  Values:  Newline-terminated strings that
will be written to C source code (F<.c>) files.   The strings are C code, but
with Perl variables whose values will be interpolated at F<xsubpp>'s runtime
by one of the C<eval EXPR> statements in ExtUtils::ParseXS.

=back

=back

=cut

sub process_typemaps {
  my ($tmap, $pwd) = @_;

  my @tm = ref $tmap ? @{$tmap} : ($tmap);

  foreach my $typemap (@tm) {
    die "Can't find $typemap in $pwd\n" unless -r $typemap;
  }

  push @tm, standard_typemap_locations( \@INC );

  my ($type_kind_ref, $proto_letter_ref, $input_expr_ref, $output_expr_ref)
    = ( {}, {}, {}, {} );

  foreach my $typemap (@tm) {
    next unless -f $typemap;
    # skip directories, binary files etc.
    warn("Warning: ignoring non-text typemap file '$typemap'\n"), next
      unless -T $typemap;
    ($type_kind_ref, $proto_letter_ref, $input_expr_ref, $output_expr_ref) =
      process_single_typemap( $typemap,
        $type_kind_ref, $proto_letter_ref, $input_expr_ref, $output_expr_ref);
  }
  return ($type_kind_ref, $proto_letter_ref, $input_expr_ref, $output_expr_ref);
}

=head2 C<process_single_typemap()>

=over 4

=item * Purpose

Process a single typemap within C<process_typemaps()>.

=item * Arguments

    ($type_kind_ref, $proto_letter_ref, $input_expr_ref, $output_expr_ref) =
      process_single_typemap( $typemap,
        $type_kind_ref, $proto_letter_ref, $input_expr_ref, $output_expr_ref);

List of five elements:  The individual typemap needing processing and four
references.

=item * Return Value

List of four references -- modified versions of those passed in as arguments.

=back

=cut

sub process_single_typemap {
  my ($typemap,
    $type_kind_ref, $proto_letter_ref, $input_expr_ref, $output_expr_ref) = @_;
  open my $TYPEMAP, '<', $typemap
    or warn ("Warning: could not open typemap file '$typemap': $!\n"), next;
  my $mode = 'Typemap';
  my $junk = "";
  my $current = \$junk;
  while (<$TYPEMAP>) {
    # skip comments
    next if /^\s*#/;
    if (/^INPUT\s*$/) {
      $mode = 'Input';   $current = \$junk;  next;
    }
    if (/^OUTPUT\s*$/) {
      $mode = 'Output';  $current = \$junk;  next;
    }
    if (/^TYPEMAP\s*$/) {
      $mode = 'Typemap'; $current = \$junk;  next;
    }
    if ($mode eq 'Typemap') {
      chomp;
      my $logged_line = $_;
      trim_whitespace($_);
      # skip blank lines
      next if /^$/;
      my($type,$kind, $proto) =
        m/^\s*(.*?\S)\s+(\S+)\s*($ExtUtils::ParseXS::Constants::proto_re*)\s*$/
          or warn(
            "Warning: File '$typemap' Line $.  '$logged_line' " .
            "TYPEMAP entry needs 2 or 3 columns\n"
          ),
          next;
      $type = tidy_type($type);
      $type_kind_ref->{$type} = $kind;
      # prototype defaults to '$'
      $proto = "\$" unless $proto;
      $proto_letter_ref->{$type} = C_string($proto);
    }
    elsif (/^\s/) {
      $$current .= $_;
    }
    elsif ($mode eq 'Input') {
      s/\s+$//;
      $input_expr_ref->{$_} = '';
      $current = \$input_expr_ref->{$_};
    }
    else {
      s/\s+$//;
      $output_expr_ref->{$_} = '';
      $current = \$output_expr_ref->{$_};
    }
  }
  close $TYPEMAP;
  return ($type_kind_ref, $proto_letter_ref, $input_expr_ref, $output_expr_ref);
}

=head2 C<make_targetable()>

=over 4

=item * Purpose

Populate C<%targetable>.

=item * Arguments

  %targetable = make_targetable(\%output_expr);
      
Reference to C<%output_expr>.

=item * Return Value

Hash.

=back

=cut

sub make_targetable {
  my $output_expr_ref = shift;
  my ($cast, $size);
  our $bal;
  $bal = qr[(?:(?>[^()]+)|\((??{ $bal })\))*]; # ()-balanced
  $cast = qr[(?:\(\s*SV\s*\*\s*\)\s*)?]; # Optional (SV*) cast
  $size = qr[,\s* (??{ $bal }) ]x; # Third arg (to setpvn)

  my %targetable;
  foreach my $key (keys %{ $output_expr_ref }) {
    # We can still bootstrap compile 're', because in code re.pm is
    # available to miniperl, and does not attempt to load the XS code.
    use re 'eval';

    my ($t, $with_size, $arg, $sarg) =
      ($output_expr_ref->{$key} =~
        m[^ \s+ sv_set ( [iunp] ) v (n)?    # Type, is_setpvn
          \s* \( \s* $cast \$arg \s* ,
          \s* ( (??{ $bal }) )    # Set from
          ( (??{ $size }) )?    # Possible sizeof set-from
          \) \s* ; \s* $
        ]x
    );
    $targetable{$key} = [$t, $with_size, $arg, $sarg] if $t;
  }
  return %targetable;
}

=head2 C<map_type()>

=over 4

=item * Purpose

Performs a mapping at several places inside C<PARAGRAPH> loop.

=item * Arguments

  $type = map_type($self, $type, $varname);

List of three arguments.

=item * Return Value

String holding augmented version of second argument.

=back

=cut

sub map_type {
  my ($self, $type, $varname) = @_;

  # C++ has :: in types too so skip this
  $type =~ tr/:/_/ unless $self->{hiertype};
  $type =~ s/^array\(([^,]*),(.*)\).*/$1 */s;
  if ($varname) {
    if ($type =~ / \( \s* \* (?= \s* \) ) /xg) {
      (substr $type, pos $type, 0) = " $varname ";
    }
    else {
      $type .= "\t$varname";
    }
  }
  return $type;
}

=head2 C<standard_XS_defs()>

=over 4

=item * Purpose

Writes to the C<.c> output file certain preprocessor directives and function
headers needed in all such files.

=item * Arguments

None.

=item * Return Value

Implicitly returns true when final C<print> statement completes.

=back

=cut

sub standard_XS_defs {
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
}

=head2 C<assign_func_args()>

=over 4

=item * Purpose

Perform assignment to the C<func_args> attribute.

=item * Arguments

  $string = assign_func_args($self, $argsref, $class);

List of three elements.  Second is an array reference; third is a string.

=item * Return Value

String.

=back

=cut

sub assign_func_args {
  my ($self, $argsref, $class) = @_;
  my @func_args = @{$argsref};
  shift @func_args if defined($class);

  for my $arg (@func_args) {
    $arg =~ s/^/&/ if $self->{in_out}->{$arg};
  }
  return join(", ", @func_args);
}

=head2 C<analyze_preprocessor_statements()>

=over 4

=item * Purpose

Within each function inside each Xsub, print to the F<.c> output file certain
preprocessor statements.

=item * Arguments

      ( $self, $XSS_work_idx, $BootCode_ref ) =
        analyze_preprocessor_statements(
          $self, $statement, $XSS_work_idx, $BootCode_ref
        );

List of four elements.

=item * Return Value

Modifed values of three of the arguments passed to the function.  In
particular, the C<XSStack> and C<InitFileCode> attributes are modified.

=back

=cut

sub analyze_preprocessor_statements {
  my ($self, $statement, $XSS_work_idx, $BootCode_ref) = @_;

  if ($statement eq 'if') {
    $XSS_work_idx = @{ $self->{XSStack} };
    push(@{ $self->{XSStack} }, {type => 'if'});
  }
  else {
    death ("Error: `$statement' with no matching `if'")
      if $self->{XSStack}->[-1]{type} ne 'if';
    if ($self->{XSStack}->[-1]{varname}) {
      push(@{ $self->{InitFileCode} }, "#endif\n");
      push(@{ $BootCode_ref },     "#endif");
    }

    my(@fns) = keys %{$self->{XSStack}->[-1]{functions}};
    if ($statement ne 'endif') {
      # Hide the functions defined in other #if branches, and reset.
      @{$self->{XSStack}->[-1]{other_functions}}{@fns} = (1) x @fns;
      @{$self->{XSStack}->[-1]}{qw(varname functions)} = ('', {});
    }
    else {
      my($tmp) = pop(@{ $self->{XSStack} });
      0 while (--$XSS_work_idx
           && $self->{XSStack}->[$XSS_work_idx]{type} ne 'if');
      # Keep all new defined functions
      push(@fns, keys %{$tmp->{other_functions}});
      @{$self->{XSStack}->[$XSS_work_idx]{functions}}{@fns} = (1) x @fns;
    }
  }
  return ($self, $XSS_work_idx, $BootCode_ref);
}

=head2 C<set_cond()>

=over 4

=item * Purpose

=item * Arguments

=item * Return Value

=back

=cut

sub set_cond {
  my ($ellipsis, $min_args, $num_args) = @_;
  my $cond;
  if ($ellipsis) {
    $cond = ($min_args ? qq(items < $min_args) : 0);
  }
  elsif ($min_args == $num_args) {
    $cond = qq(items != $min_args);
  }
  else {
    $cond = qq(items < $min_args || items > $num_args);
  }
  return $cond;
}

=head2 C<Warn()>

=over 4

=item * Purpose

=item * Arguments

=item * Return Value

=back

=cut

sub Warn {
  my $self = shift;
  # work out the line number
  my $warn_line_number = $self->{line_no}->[@{ $self->{line_no} } - @{ $self->{line} } -1];

  print STDERR "@_ in $self->{filename}, line $warn_line_number\n";
}

=head2 C<blurt()>

=over 4

=item * Purpose

=item * Arguments

=item * Return Value

=back

=cut

sub blurt {
  my $self = shift;
  Warn($self, @_);
  $self->{errors}++
}

=head2 C<death()>

=over 4

=item * Purpose

=item * Arguments

=item * Return Value

=back

=cut

sub death {
  my $self = shift;
  Warn($self, @_);
  exit 1;
}

=head2 C<check_conditional_preprocessor_statements()>

=over 4

=item * Purpose

=item * Arguments

=item * Return Value

=back

=cut

sub check_conditional_preprocessor_statements {
  my ($self) = @_;
  my @cpp = grep(/^\#\s*(?:if|e\w+)/, @{ $self->{line} });
  if (@cpp) {
    my $cpplevel;
    for my $cpp (@cpp) {
      if ($cpp =~ /^\#\s*if/) {
        $cpplevel++;
      }
      elsif (!$cpplevel) {
        Warn( $self, "Warning: #else/elif/endif without #if in this function");
        print STDERR "    (precede it with a blank line if the matching #if is outside the function)\n"
          if $self->{XSStack}->[-1]{type} eq 'if';
        return;
      }
      elsif ($cpp =~ /^\#\s*endif/) {
        $cpplevel--;
      }
    }
    Warn( $self, "Warning: #if without #endif in this function") if $cpplevel;
  }
}

1;

# vim: ts=2 sw=2 et:
