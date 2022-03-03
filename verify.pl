#!/usr/bin/perl
use warnings;
use strict;
use Data::Dumper;
use File::Temp;
use File::Copy;

my %classes;
my %verified;

my @files = @ARGV;
my @cpp_files = grep { /\.cpp$/ } @files;
my @hpp_files = grep { /\.hpp$/ } @files;

# Process cpp files first, since we might have several cpp files with
# the same class name.
foreach my $file (@cpp_files) {
  read_class_names($file);
  foreach my $class (keys %classes) {
    my $class_name = $classes{$class}{name};
    verify($file, $class, $class_name);
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
    verify($file, $class, $class_name);
  }
}

print STDERR Dumper(\%verified);

sub read_class_names {
  my ($file) = @_;
  open my $in, '<', $file or die "Can't read file: $!";
  my $aux;
  my $class;
  my $peek_aux = 0;
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
    if ($_ =~ m/^(struct|class)\s*([_0-9a-zA-Z]+)/) {
      $class = $2;
    } elsif ($_ =~ m/(struct|class)\s*([_0-9a-zA-Z]+).* : /) {
      $class = $2;
    }
    if ($_ !~ m/#define/ and $_ =~ m/DECLARE_CPU_JIT_AUX_FUNCTIONS\(/) {
      die "$file" if !defined($class);
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
}

sub verify {
  my ($file, $class, $class_name) = @_;
  open my $in, '<', $file or die "Can't read file: $!";
  my $in_class = 0;
  while (<$in>) {
    if ($_ =~ m/(?:struct|class)?\s+$class/ or $_ =~ m/$class\(/) {
      $in_class = 1;
    }
    if ($_ =~ m/jit_name\(\)/ and $in_class) {
      $verified{$class_name}++;
      return;
    }
  }
  close $in;
}
