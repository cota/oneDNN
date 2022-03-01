#!/usr/bin/perl
use warnings;
use strict;
use Data::Dumper;
use File::Temp;
use File::Copy;

my %classes;
my @replaced;
my @found;

my @files = @ARGV;
my @cpp_files = grep { /\.cpp$/ } @files;
my @hpp_files = grep { /\.hpp$/ } @files;

# Process cpp files first, since we might have several cpp files with
# the same class name.
foreach my $file (@cpp_files) {
  read_class_names($file);
  foreach my $class (keys %classes) {
    my $class_name = $classes{$class}{name};
    prepend_generator_name($file, $class, $class_name);
  }
  undef %classes;
}

# Now process the hpp file headers, and then go through all files.
# Note that we do not modify constructors twice, so this should be OK
# for cpp files.
foreach my $file (@hpp_files) {
  read_class_names($file);
}
foreach my $file (@files) {
  foreach my $class (keys %classes) {
    my $class_name = $classes{$class}{name};
    prepend_generator_name($file, $class, $class_name);
  }
}

my %replaced;
foreach (@replaced) {
  $replaced{$_}++;
}
foreach (@found) {
  $replaced{$_}--;
}
foreach my $k (keys %replaced) {
  if ($replaced{$k} == 0) {
    delete $replaced{$k};
  }
}
#print STDERR Dumper(\@found);
#print STDERR Dumper(\@replaced);
print STDERR Dumper(\%replaced);

sub read_class_names {
  my ($file) = @_;
  open my $in, '<', $file or die "Can't read file: $!";
  my $aux;
  my $class;
  my $peek_aux = 0;
  my $peek_class = 0;
  my $maybe_class;
  while (<$in>) {
    if ($peek_aux) {
      die if !defined($class);
      if ($_ =~ m/\s*([^)]+)\)/) {
        push_aux($1, $class, $file);
        undef $class;  # prevent it from being assigned again.
      } else {
        die "Cannot find match after peek_aux=1: $_";
      }
      $peek_aux = 0;
    }
    if ($peek_class) {
      die if !defined($maybe_class);
      $peek_class++;
      if ($_ =~ /public\s+jit_generator/) {
        $class = $maybe_class;
        $peek_class = 0;
      } else {
      }
      if ($peek_class > 4) {
        $peek_class = 0;
        undef $maybe_class;
        undef $class;
      }
    }
    if ($_ =~ m/^(struct|class)\s*([_0-9a-zA-Z]+)/) {
      $maybe_class = $2;
      if ($_ =~ /.*:.*public jit_generator/) {
        $class = $maybe_class;
      } else {
        $peek_class = 1;
      }
    }
    if (defined($class) and $_ =~ m/DECLARE_CPU_JIT_AUX_FUNCTIONS\(/) {
      if ($_ =~ m/\($/) {
        $peek_aux = 1;
      } elsif ($_ =~ m/\(([^)]+)\)/) {
        push_aux($1, $class, $file);
        undef $class;
      } else {
        die "Malformed DECLARE_CPU_JIT_AUX_FUNCTIONS: $_";
      }
    }
  }
  close $in;
}

sub push_aux {
  my ($aux, $class, $file) = @_;
  $aux =~ s/^\s*(.*?)\s*$/$1/;
  $classes{$class}{name} = $aux;
  push @{ $classes{$class}{files} }, $file;
  push @found, "$class";
}

sub prepend_generator_name {
  my ($file, $class, $class_name) = @_;
  open my $in, '<', $file or die "Can't read file: $!";
  my $tmp = File::Temp->new(TEMPLATE => 'tempXXXXX',
                            DIR => '/tmp',
                            SUFFIX => '.transform');
  open my $out, '>', $tmp->filename or die "Cannot open file $tmp->filename: $!";
  my $peek = 0;
  while (<$in>) {
    if ($peek) {
      $peek++;
      if ($_ =~ m/;$/) {
        $peek = 0;
      } elsif ($_ =~ s/^(.*jit_generator\()([^"])/$1"$class_name", $2/) {
        push @replaced, "$class";
        $peek = 0;
      } elsif ($_ =~ s/:(\s*.*_\(.*)/: jit_generator("$class_name"),$1/) {
        push @replaced, "$class";
        $peek = 0;
      } elsif ($_ =~ s/:( (?:jcp|params)\(.*\{)/: jit_generator("$class_name"),$1/) {
        # Special-case these because they don't follow the 'member_' convention.
        push @replaced, "$class";
        $peek = 0;
      } elsif ($_ =~ s/:(\s*[a-zA-Z].*) \{/:$1, jit_generator("$class_name") {/) {
        push @replaced, "$class";
        $peek = 0;
      } elsif ($_ =~ s/(\s+:\s+)/$1jit_generator("$class_name"), /) {
        push @replaced, "$class";
        $peek = 0;
      }
      if ($peek > 6) {
        $peek = 0;
      }
    }
    # Find the constructor
    if ($_ !~ m/;$/ and $_ =~ m/^\s*(?:${class}(?:<[^>]+>)?::)?$class\([^)]*/) {
      if ($_ =~ s/^(.*(?:::)?$class\([^)]*\)\s*:.*jit_generator\()([^"])/$1"$class_name", $2/) {
        push @replaced, "$class";
      } elsif ($_ =~ s/^(.*(?:::)?$class\([^)]*\)\s*:)(\s*.*_\(.*)\{/$1 jit_generator("$class_name"), $2\{/) {
        # foo(...) : local_var_(bar) {
        push @replaced, "$class";
      } elsif ($_ =~ s/^(.*(?:::)?$class\([^)]*\)\s*: [A-Za-z].*)\{\}/$1, jit_generator("$class_name") {}/) {
        # foo(...) : [..no jit generator..] {}
        push @replaced, "$class";
      } elsif ($_ =~ s/^(.*(?:::)?$class\([^)]*\)\s*)\{/$1: jit_generator("$class_name") {/) {
        # foo(...) {
        push @replaced, "$class";
      } else {
        $peek = 1;
      }
    } elsif ($_ =~ m/^.*::$class\(/) {
      $peek = 1;
    }
    print $out $_;
  }
  close $in;
  close $out;

  File::Copy::copy($tmp->filename, $file);
}
