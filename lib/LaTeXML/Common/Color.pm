# /=====================================================================\ #
# |  LaTeXML::Common::Color             ,...                            | #
# | Representation of colors in various color models                    | #
# |=====================================================================| #
# | Part of LaTeXML:                                                    | #
# |  Public domain software, produced as part of work done by the       | #
# |  United States Government & not subject to copyright in the US.     | #
# |---------------------------------------------------------------------| #
# | Bruce Miller <bruce.miller@nist.gov>                        #_#     | #
# | http://dlmf.nist.gov/LaTeXML/                              (o o)    | #
# \=========================================================ooo==U==ooo=/ #
package LaTeXML::Common::Color;
use strict;
use warnings;
use LaTeXML::Global;
use base qw(LaTeXML::Object);

#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
# Color objects; objects representing color in "arbitrary" color models
# We'd like to provide a set of "core" color models (rgb,cmy,cmyk,hsb)
# and allow derived color models (with scaled ranges, or whatever; see xcolor).
# There is some awkwardness in that we'd like to support the core models
# directly with built-in code, but support derived models that possibly
# are defined in terms of macros defined as part of a style file.
#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
# NOTE: This class is in Common since it could conceivably be useful
# in Postprocessing --- But the API, includes, etc haven't been tuned for that!
# They only use $STATE to get derived color information, Error, min & max.
#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
# Color Objects

our %core_color_models = map { ($_ => 1) } qw(rgb cmy cmyk hsb gray);    # [CONSTANT]

# slightly contrived to avoid 'use'ing all the models in here
# (which causes compiler redefined issues, and preloads them all)
sub new {
  my ($class, @components) = @_;
  if (ref $class) {    # from $self->new(...)
    return bless [$$class[0], @components], ref $class; }
  else {               # Else, $model is the 1st element of @components;
    my $model = shift(@components);
    my $type  = ($core_color_models{$model} ? $model : 'Derived');
    my $class = 'LaTeXML::Common::Color::' . $type;
    if (($type eq 'Derived')
      && !$LaTeXML::Global::STATE->lookupValue('derived_color_model_' . $model)) {
      Error('unexpected', $model, undef, "Unrecognized color model '$model'"); }
    my $module = $class . '.pm';
    $module =~ s|::|/|g;
    require $module unless exists $INC{$module};    # Load if not already loaded
    return bless [$model, @components], $class; } }

sub model {
  my ($self) = @_;
  return $$self[0]; }

sub components {
  my ($self) = @_;
  my ($m, @comp) = @$self;
  return @comp; }

# Convert a color to another model
sub convert {
  my ($self, $tomodel) = @_;
  if ($self->model eq $tomodel) {    # Already the correct model
    return $self; }
  elsif ($core_color_models{$tomodel}) {    # target must be core model
    return $self->toCore->$tomodel; }
  elsif (my $data = $LaTeXML::Global::STATE->lookupValue('derived_color_model_' . $tomodel)) { # Ah, target is a derived color
    my $coremodel   = $$data[0];
    my $convertfrom = $$data[2];
    return &{$convertfrom}($self->$coremodel); }
  else {
    Error('unexpected', $tomodel, undef, "Unrecognized color model '$tomodel'");
    return $self; } }

sub toString {
  my ($self) = @_;
  my ($model, @comp) = @$self;
  return $model . "(" . join(',', @comp) . ")"; }

sub toHex {
  my ($self) = @_;
  return $self->rgb->toHex; }

sub toAttribute {
  my ($self) = @_;
  return $self->rgb->toHex; }

# Convert the color to a core model; Assume it already is!
# Color::Derived MUST override this...
sub toCore { my ($self) = @_; return $self; }

#======================================================================
# By default, just complement components (works for rgb, cmy, gray)
sub complement {
  my ($self) = @_;
  return $self->new(map { 1 - $_ } $self->components); }

# Mix $self*$fraction + $color*(1-$fraction)
sub mix {
  my ($self, $color, $fraction) = @_;
  $color = $color->convert($self->model) unless $self->model eq $color->model;
  my @a = $self->components;
  my @b = $color->components;
  return $self->new(map { $fraction * $a[$_] + (1 - $fraction) * $b[$_] } 0 .. $#a); }

sub add {
  my ($self, $color) = @_;
  $color = $color->convert($self->model) unless $self->model eq $color->model;
  my @a = $self->components;
  my @b = $color->components;
  return $self->new(map { $a[$_] + $b[$_] } 0 .. $#a); }

# The next 2 methods multiply the components of a color by some value(s)
# This assumes that such a thing makes sense in the given model, for some purpose.
# It may be that the components should be truncated to 1 (or some other max?)

# Multiply all components by a constant
sub scale {
  my ($self, $m) = @_;
  return $self->new(map { $m * $_ } $self->components); }

# Multiply by a vector (must have same number of components)
# This may or may not make sense for any given color model or purpose.
sub multiply {
  my ($self, @m) = @_;
  my @c = $self->components;
  if (scalar(@m) != scalar(@c)) {
    Error('misdefined', 'multiply', "Multiplying color components by wrong number of parts",
      "The color is " . ToString($self) . " while the multipliers are " . join(',', @m));
    return $self; }
  else {
    return $self->new(map { $c[$_] * $m[$_] } 0 .. $#c); } }

#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
1;