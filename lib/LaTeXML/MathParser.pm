# /=====================================================================\ #
# |  LaTeXML::MathParser                                                | #
# | Parse Math                                                          | #
# |=====================================================================| #
# | Part of LaTeXML:                                                    | #
# |  Public domain software, produced as part of work done by the       | #
# |  United States Government & not subject to copyright in the US.     | #
# |---------------------------------------------------------------------| #
# | Bruce Miller <bruce.miller@nist.gov>                        #_#     | #
# | http://dlmf.nist.gov/LaTeXML/                              (o o)    | #
# \=========================================================ooo==U==ooo=/ #
# ================================================================================
# LaTeXML::MathParser  Math Parser for LaTeXML using Parse::RecDescent.
# Parse the intermediate representation generated by the TeX processor.
# ================================================================================
package LaTeXML::MathParser;
use strict;
use Parse::RecDescent;
use LaTeXML::Global;
use XML::LibXML;
use base (qw(Exporter));

our @EXPORT_OK = (qw(&Lookup &New &Apply &ApplyNary &recApply
		     &Annotate &InvisibleTimes
		     &NewFormulae &NewFormula &NewCollection
		     &ApplyDelimited &NewScripts
		     &LeftRec
		     &Arg &Problem &MaybeFunction
		     &isMatchingClose &Fence));
our %EXPORT_TAGS = (constructors
		    => [qw(&Lookup &New &Apply &ApplyNary &recApply
			   &Annotate &InvisibleTimes
			   &NewFormulae &NewFormula &NewCollection
			   &ApplyDelimited &NewScripts
			   &LeftRec
			   &Arg &Problem &MaybeFunction
			   &isMatchingClose &Fence)]);
our $nsURI = "http://dlmf.nist.gov/LaTeXML";
our $nsXML = "http://www.w3.org/XML/1998/namespace";
#our $DEFAULT_FONT = LaTeXML::MathFont->default();
our $DEFAULT_FONT = LaTeXML::MathFont->new(family=>'serif', series=>'medium',
					   shape=>'upright', size=>'normal',
					   color=>'black');

# ================================================================================
sub new {
  my($class,%options)=@_;
  require LaTeXML::MathGrammar;

  my $internalparser = LaTeXML::MathGrammar->new();
  die("Math Parser grammar failed") unless $internalparser;

  my $self = bless {internalparser => $internalparser},$class;
  $self; }

sub parseMath {
  my($self,$document,%options)=@_;
  local $LaTeXML::MathParser::DOCUMENT = $document;
  $self->clear;			# Not reentrant!
  $$self{idcache}={};
  foreach my $node ($document->findnodes("//*[\@id]")){
    $$self{idcache}{$node->getAttribute('id')} = $node; }

  if(my @math =  $document->findnodes('descendant-or-self::ltx:XMath')){
    NoteBegin("Math Parsing"); NoteProgress(scalar(@math)." formulae ...");
    local $LaTeXML::MathParser::CAPTURE = $document->getDocument->documentElement->addNewChild($nsURI,'XMath');
    foreach my $math (@math){
      $self->parse($math,$document); }

    $LaTeXML::MathParser::CAPTURE->parentNode->removeChild($LaTeXML::MathParser::CAPTURE);

    NoteProgress("\nMath parsing succeeded:"
		 .join('',map( "\n   $_: ".$$self{passed}{$_}."/".($$self{passed}{$_}+$$self{failed}{$_}),
			       grep( $$self{passed}{$_}+$$self{failed}{$_},
				     keys %{$$self{passed}})))."\n");
    if(my @unk = keys %{$$self{unknowns}}){
      NoteProgress("Symbols assumed as simple identifiers (with # of occurences):\n   "
		   .join(', ',map("'$_' ($$self{unknowns}{$_})",sort @unk))."\n"); }
    if(my @funcs = keys %{$$self{maybe_functions}}){
      NoteProgress("Possibly used as functions?\n  "
		   .join(', ',map("'$_' ($$self{maybe_functions}{$_}/$$self{unknowns}{$_} usages)",
				  sort @funcs))."\n"); }
    NoteEnd("Math Parsing");  }
  $document; }

# ================================================================================
sub clear {
  my($self)=@_;
  $$self{passed}={XMath=>0,XMArg=>0,XMWrap=>0};
  $$self{failed}={XMath=>0,XMArg=>0,XMWrap=>0};
  $$self{unknowns}={};
  $$self{maybe_functions}={};
  $$self{n_parsed}=0;
}

sub token_prettyname {
  my($node)=@_;
  my $name = $node->getAttribute('name');
  if(defined $name){}
  elsif($name = $node->textContent){
    my $font = $LaTeXML::MathParser::DOCUMENT->getNodeFont($node);
    my %attr = $font->relativeTo($DEFAULT_FONT);
    my $desc = join(' ',values %attr);
    $name .= "{$desc}" if $desc; }
  else {
    $name = 'Unknown';
    Warn("MathParser: What is this: \"".$node->toString."\"?"); }
  $name; }

sub note_unknown {
  my($self,$node)=@_;
  my $name = token_prettyname($node);
  $$self{unknowns}{$name}++; }

# ================================================================================
# Some more XML utilities, but math specific (?)

sub new_node {
  my($tag)=@_;
  my $node = $LaTeXML::MathParser::CAPTURE->addNewChild($nsURI,$tag);
  $node; }

sub element_nodes {
  my($node)=@_;
  grep( $_->nodeType == XML_ELEMENT_NODE, $node->childNodes); }


# Append the given nodes (which might also be array ref's of nodes, or even strings)
# to $node.  This takes care to clone any node that already has a parent.
# We have to be _extremely_ careful when rearranging trees when using XML::LibXML!!!
# If we add one node to another, it is _silently_ removed from it's previous
# parent, if any! Hopefully, this test is sufficient?
sub append_nodes {
  my($node,@children)=@_;
  foreach my $child (@children){

    my $parent = $child->parentNode;
    if($parent && ! $parent->isSameNode($LaTeXML::MathParser::CAPTURE)){
      insert_clone($node,$child); }
    else {
      $node->appendChild($child); }}}

# insert the clone of $node into $parent.
# This version attempts to use the namespace existing in $parent
# to avoid introducing new declarations.
sub insert_clone {
  my($parent,$node)=@_;
  my $new = $parent->addNewChild($node->namespaceURI,$node->localname);
  foreach my $attr ($node->attributes){
    if($attr->nodeType == XML_ATTRIBUTE_NODE){
      if(my $ns = $attr->namespaceURI){
	$new->setAttributeNS($ns,$attr->localname,$attr->getValue); }
      else {
	$new->setAttribute($attr->localname,$attr->getValue); }}}
  foreach my $child ($node->childNodes){
    my $type = $child->nodeType;
    if   ($type == XML_ELEMENT_NODE){ insert_clone($new,$child); }
    elsif($type == XML_TEXT_NODE)     { $new->appendText($child->textContent); }
    # entity, cdata, ...
  }
  $new; }

# Get the Token's  meaning, else name, else content, else role
sub getTokenMeaning {
  my($node)=@_;
  my $x;
  (defined ($x=$node->getAttribute('meaning')) ? $x
   : (defined ($x=$node->getAttribute('name')) ? $x
      : (($x= $node->textContent) ne '' ? $x
	 : (defined ($x=$node->getAttribute('role')) ? $x
	    : undef)))); }

sub getTokenContent { # Get the Token's content, or fall back to name.
  my($node)=@_;
  my $x;
  (($x=$node->textContent) ne '' ? $x
   : (defined ($x=$node->getAttribute('name')) ? $x
      : undef)); }

sub node_string {
  my($node,$document)=@_;
  my($string,$x);
#  if(defined ($x=$node->getAttribute('tex'))){ $string=$x; }
#  elsif(defined ($x=$node->getAttribute('name'))) { $string=$x; }
#  elsif(($node->localname eq 'XMTok')&& (defined ($x=$node->textContent))){ $string=$x; }
#  else{ $string=$node->localname; }

#  $string = text_form($node);
#  ($node->getAttribute('role')||'Unknown').'['.$string.']'; }
  my $role = $node->getAttribute('role') || 'UNKNOWN';
  my $box = $document->getNodeBox($node);
  ($box ? ToString($box) : text_form($node)). "[[$role]]"; }

sub node_location {
  my($node)=@_;
  my $n = $node;
  while($n && (ref $n ne 'XML::LibXML::Document')
	&& !$n->getAttribute('refnum') && !$n->getAttribute('label')){
    $n = $n->parentNode; }
  if($n && (ref $n ne 'XML::LibXML::Document')){
    my($r,$l)=($n->getAttribute('refnum'),$n->getAttribute('label'));
    ($r && $l ? "$r ($l)" : $r || $l); }
  else {
    'Unknown'; }}

#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
# Parser
#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
# We do a depth-first traversal of the content of the XMath element,
# since various sub-elements act as containers of nominally complete
# subexpressions.
# XMArg and XMWrap
sub parse {
  my($self,$xnode,$document)=@_;
  local $LaTeXML::MathParser::STRICT = 1;
  local $LaTeXML::MathParser::WARNED = 0;
  local $LaTeXML::MathParser::XNODE  = $xnode;

  if(my $result = $self->parse_rec($xnode,'Anything,',$document)){
    # Add text representation to the containing Math element.
    $xnode->parentNode->setAttribute('text',text_form($result)); }
}

our %TAG_FEEDBACK=(XMArg=>'a',XMWrap=>'w');
# Recursively parse a node with some internal structure
# by first parsing any structured children, then it's content.
sub parse_rec {
  my($self,$node,$rule,$document)=@_;
  $self->parse_children($node,$document);
  my $tag  = $node->localname;
  if(my $requested_rule = $node->getAttribute('rule')){
    $rule = $requested_rule; }
  if(my $result= $self->parse_internal($node,$document,$rule)){
    $$self{passed}{$tag}++;
   if($tag eq 'XMath'){	# Replace content of XMath
     NoteProgress('['.++$$self{n_parsed}.']');
     map($node->removeChild($_),element_nodes($node));
     append_nodes($node,$result); }
    else {			# Replace node for XMArg, XMWrap; preserve some attributes
      NoteProgress($TAG_FEEDBACK{$tag}||'.') if $LaTeXML::Global::STATE->lookupValue('VERBOSITY') >= 1;
      if(my $role = $node->getAttribute('role')){
	$result->setAttribute('role',$role); }
      if(my $id = $node->getAttribute('id')){ # Update the node associated w/ id
	$result->setAttribute('id'=>$id);
	$$self{idcache}{$id} = $result; }
      $node->parentNode->replaceChild($result,$node); }
    $result; }
  else {
    if($tag eq 'XMath'){
      NoteProgress('[F'.++$$self{n_parsed}.']'); }
    elsif($tag eq 'XMArg'){
      NoteProgress('-a') if $LaTeXML::Global::STATE->lookupValue('VERBOSITY') >= 1; }
    $$self{failed}{$tag}++;
    undef; }}

# Depth first parsing of XMArg nodes.
sub parse_children {
  my($self,$node,$document)=@_;
  foreach my $child (element_nodes($node)){
    my $tag = $child->localname;
    if($tag eq 'XMArg'){
      $self->parse_rec($child,'Anything',$document); }
    elsif($tag eq 'XMWrap'){
      local $LaTeXML::MathParser::STRICT=0;
      $self->parse_rec($child,'Anything',$document); }
#    elsif(($tag eq 'XMApp')||($tag eq 'XMDual')){
    elsif($tag =~ /^(XMApp|XMDual|XMArray|XMRow|XMCell)$/){
      $self->parse_children($child,$document); }
}}


# ================================================================================

sub parse_internal {
  my($self,$mathnode,$document,$rule)=@_;
  #  Remove Hints!
  my @nodes = element_nodes($mathnode);
  @nodes = grep( $_->localname ne 'XMHint', @nodes);

  # Extract trailing punctuation, if rule allows it.
  my ($punct, $result,$textified);
  if($rule =~ s/,$//){
    my ($x,$r) = ($nodes[$#nodes]);
    $punct = ($x && ($x->localname eq 'XMTok')
	      && ($r = $x->getAttribute('role'))
	      && (($r eq 'PUNCT')||($r eq 'PERIOD'))
	      ? pop(@nodes) : ''); }
  my $nnodes = scalar(@nodes);
  
  if($nnodes == 0){	     # No nodes => Empty  (maybe the wrong thing to do, but ...
    $result = New('Empty'); }
  elsif($nnodes == 1){		# One node? What's to parse?
    $result = $nodes[0]; }
  else {
    if($LaTeXML::MathParser::DEBUG){
      if(my $string = join(' ',map(node_string($_,$document),@nodes))){
	print STDERR "Parsing \"$string\"\n"; }}

    # Generate a textual token for each node; The parser operates on this encoded string.
    local $LaTeXML::MathParser::LEXEMES = {};
    my $i = 0;
    $textified='';
    foreach my $node (@nodes){
      my $tag = $node->localname;
      my $rnode = $node;
      if($tag eq 'XMRef'){
	if(my $id = $node->getAttribute('id')){
	  $rnode = $$self{idcache}{$id};
	  $tag = $rnode->localname; }}
      my $text = getTokenMeaning($node);
      $text = 'Unknown' unless defined $text;
      my $role = $rnode->getAttribute('role');
#      $role = ($tag eq 'XMTok' ? 'UNKNOWN' : 'ATOM') unless defined $role;
      if(!defined $role){
	if($tag eq 'XMTok'){
	  $role = 'UNKNOWN'; }
	elsif($tag eq 'XMDual'){
	  $role = $node->firstChild->getAttribute('role'); }
	$role = 'ATOM' unless defined $role; }
      my $lexeme      = $role.":".$text.":".++$i;
      $lexeme =~ s/\s//g;
      $self->note_unknown($rnode)
	if ($role eq 'UNKNOWN') && $LaTeXML::MathParser::STRICT;
      $$LaTeXML::MathParser::LEXEMES{$lexeme} = $node;
      $textified .= ' '.$lexeme; }

    #print STDERR "MathParse Node:\"".join(' ',map(node_string($_,$document),@nodes))."\"\n => \"$textified\"\n";

    # Finally, apply the parser to the textified sequence.
    local $LaTeXML::MathParser::PARSER = $self;
    $result = $$self{internalparser}->$rule(\$textified); }

  # Failure: report on what/where
  # NOTE: Should do script hack??
  if((! defined $result) || $textified){
    if($LaTeXML::MathParser::STRICT || (($STATE->lookupValue('VERBOSITY')||0)>1)){
      if(! $LaTeXML::MathParser::WARNED){
	$LaTeXML::MathParser::WARNED=1;
	my $box = $document->getNodeBox($LaTeXML::MathParser::XNODE);
	Warn("In formula \"".ToString($box)." from ".$box->getLocator); }
      $textified =~ s/^\s*//;
      my @rest=split(/ /,$textified);
      my $pos = scalar(@nodes) - scalar(@rest);
      my $parsed  = join(' ',map(node_string($_,$document),@nodes[0..$pos-1]));
      my $toparse = join(' ',map(node_string($_,$document),@nodes[$pos..$#nodes]));
      my $lexeme = node_location($nodes[$pos] || $nodes[$pos-1] || $mathnode);
      Warn("  MathParser failed to match rule $rule for ".$mathnode->localname." at pos. $pos in $lexeme at\n   "
	   . ($parsed ? $parsed."   \n".(' ' x (length($parsed)-2)) : '')."> ".$toparse);
    }
    undef; }
  # Success!
  else {
    $result->setAttribute('punctuation',getTokenContent($punct)) if $punct;
    $result; }}

# ================================================================================
# Conversion to a less ambiguous, mostly-prefix form.

sub text_form {
  my($node)=@_;
#  $self->textrec($node,0); }
# Hmm, Something Weird is broken!!!!
# With <, I get "unterminated entity reference" !?!?!?
#  my $text= $self->textrec($node,0); 
  my $text= textrec($node,undef); 
  $text =~ s/</less/g;
  $text; }


our %PREFIX_ALIAS=(SUPERSCRIPTOP=>'^',SUBSCRIPTOP=>'_', "\x{2062}"=>'*',
		   eq=>'=',less=>'<',greater=>'<',
		   plus=>'+',minus=>'-',div=>'/');
# Put infix, along with `binding power'
our %IS_INFIX = (METARELOP=>1, 
		 RELOP=>2, ARROW=>2,
		 ADDOP=>10, MULOP=>100, 
		 SUPERSCRIPTOP=>1000, SUBSCRIPTOP=>1000);

sub textrec {
  my($node, $outer_bp,$outer_name)=@_;
  my $tag = $node->localname;
  $outer_bp = 0 unless defined $outer_bp;
  $outer_name = '' unless defined $outer_name;
  if($tag eq 'XMApp') {
    my($op,@args) = element_nodes($node);
    my $name = (($op->localname eq 'XMTok') && getTokenMeaning($op)) || 'unknown';
    my $role  =  $op->getAttribute('role') || 'Unknown';
    my ($bp,$string);
    if($bp = $IS_INFIX{$role}){
      # Format as infix.
      $string = (scalar(@args) == 1 # unless a single arg; then prefix.
		  ? textrec($op) .' '.textrec($args[0],$bp,$name)
		  : join(' '. textrec($op) .' ',map(textrec($_,$bp,$name), @args))); }
    elsif($role eq 'POSTFIX'){
      $bp = 10000;
      $string = textrec($args[0],$bp,$name).textrec($op); }
    elsif($name eq 'MultiRelation'){
      $bp = 2;
      $string = join(' ',map(textrec($_,$bp,$name),@args)); }
    elsif($name eq 'Fenced'){
      $bp = -1;			# to force parentheses
      $string = join(', ',map(textrec($_),@args)); }
    else {
      $bp = 500;
      $string = textrec($op,10000,$name) .'@(' . join(', ',map(textrec($_),@args)). ')'; }
    (($bp < $outer_bp)||(($bp==$outer_bp)&&($name ne $outer_name)) ? '('.$string.')' : $string); }
  elsif($tag eq 'XMDual'){
    my($content,$presentation)=element_nodes($node);
    textrec($content,$outer_bp,$outer_name); } # Just send out the semantic form.
  elsif($tag eq 'XMTok'){
    my $name = getTokenMeaning($node);
    $name = 'Unknown' unless defined $name;
    $PREFIX_ALIAS{$name} || $name; }
  elsif($tag eq 'XMWrap'){
    # ??
    join('@',map(textrec($_), element_nodes($node))); }
  elsif($tag eq 'XMArray'){
    my $name = $node->getAttribute('meaning') || $node->getAttribute('name')
      || 'Array';
    my @rows = ();
    foreach my $row (element_nodes($node)){
      push(@rows,
       '['.join(', ',map(textrec($_->firstChild),element_nodes($row))).']');}
    $name.'['.join(', ',@rows).']';  }
  else {
    my $string = ($tag eq 'XMText' ? $node->textContent : $node->getAttribute('tex') || '?');
      "[$string]"; }}

#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
# Cute! Were it NOT for Sub/Superscripts, the whole parsing process only
# builds a new superstructure around the sequence of token nodes in the input.
# Thus, any internal structure is unchanged.
#  They get re-parented, but if the parse fails, we've only got to put them
# BACK into the original node, to recover the original arrangment!!!
# Thus, we don't have to clone, and deal with namespace duplication.
# ...
# EXCEPT, as I said, for sub/superscripts!!!!
#

#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
# Constructors used in grammar
# All the tree construction in the grammar should come through these operations.
# We have to be _extremely_ careful about cloning nodes when using addXML::LibXML!!!
# If we add one node to another, it is _silently_ removed from any parent it may have had!
#%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

# ================================================================================
# Low-level accessors
sub Lookup {
  my($lexeme)=@_;
  $$LaTeXML::MathParser::LEXEMES{$lexeme}; }

# Make a new Token node with given name, content, and attributes.
# $content is an array of nodes (which may need to be cloned if still attached)
sub New {
  my($name,$content,%attributes)=@_;
#  my $node=XML::LibXML::Element->new('XMTok');
#  $node->setNamespace($nsURI,'ltx',1);
  my $node=new_node('XMTok');

  $node->appendText($content) if $content;
  $attributes{name} = $name if $name;
  foreach my $key (sort keys %attributes){
    my $value = $attributes{$key};
    if(defined $value){
      $value = getTokenContent($value) if ref $value;
      $node->setAttribute($key, $value); }}
  $node; }


# Get n-th arg of an XMApp.
sub Arg {
  my($node,$n)=@_;
  my @args = element_nodes($node);
  $args[$n]; }			# will get cloned if/when needed.

# Add more attributes to a node.
sub Annotate {
  my($node,%attribs)=@_;
  foreach my $attr (sort keys %attribs){
    my $value = $attribs{$attr};
    $value = getTokenContent($value) if ref $value;
    $node->setAttribute($attr,$value) if defined $value; }
  $node; }

# ================================================================================
# Mid-level constructors

# Apply $op to the list of arguments
sub Apply {
  my($op,@args)=@_;
#  my $node=XML::LibXML::Element->new('XMApp');
#  $node->setNamespace($nsURI,'ltx',1);
  my $node=new_node('XMApp');
  append_nodes($node,$op,@args);
  $node; }

# Apply $op to a `delimited' list of arguments of the form
#     open, expr (punct expr)* close
# after extracting the opening and closing delimiters, and the separating punctuation
sub ApplyDelimited {
  my($op,@stuff)=@_;
  my $open =shift(@stuff);
  my $close=pop(@stuff);
  $open  = getTokenContent($open)  if ref $open;
  $close = getTokenContent($close) if ref $close;
  my ($seps,@args)=extract_separators(@stuff);
  Apply(Annotate($op, argopen=>$open, argclose=>$close, separators=>$seps),@args); }

# Given a sequence of operators, form the nested application op(op(...(arg)))
sub recApply {
  my(@ops)=@_;
  (scalar(@ops)>1 ? Apply(shift(@ops),recApply(@ops)) : $ops[0]); }

# Given  alternating expressions & separators (punctuation,...)
# extract the separators as a concatenated string,
# returning (separators, args...)
sub extract_separators {
  my(@stuff)=@_;
  my ($punct,@args);
  if(@stuff){
    push(@args,shift(@stuff));
    while(@stuff){
      $punct .= shift(@stuff)->textContent;
      push(@args,shift(@stuff)); }}
  ($punct,@args); }

# ================================================================================
# Some special cases 

sub InvisibleTimes {
  New('',"\x{2062}", role=>'MULOP'); }


# OK, what about \left. or \right. !!?!?!!?!?!?
# Make customizable?
# Should I just check left@right against enclose1 ?
our %balanced = ( '(' => ')', '['=>']', '{'=>'}', 
		  '|'=>'|', '||'=>'||',
		  "\x{230A}"=>"\x{230B}", # lfloor, rfloor
		  "\x{2308}"=>"\x{2309}", # lceil, rceil
		  "\x{2329}"=>"\x{232A}");
our %enclose1 = ( '(@)'=>'Fenced', '[@]'=>'Fenced', '{@}'=>'Set',
		  '|@|'=>'Abs', '||@||'=>'norm',
		  "\x{230A}@\x{230B}"=>'Floor',
		  "\x{2308}@\x{2309}"=>'Ceiling' );
our %enclose2 = ( '(@)'=>'OpenInterval', '[@]'=>'ClosedInterval',
		  '(@]'=>'OpenLeftInterval', '[@)'=>'OpenRightInterval',
		  '{@}'=>'Set',
		  # Nah, too weird.
		  #'{@}'=>'SchwarzianDerivative',
		  # "\x{2329}@\x{232A}"=>'Distribution'
		);
our %encloseN = ( '(@)'=>'Vector','{@}'=>'Set',);

sub isMatchingClose {
  my($open,$close)=@_;
  my $oname = getTokenContent($open);
  my $cname = getTokenContent($close);
  my $expect = $balanced{$oname};
  (defined $expect) && ($expect eq $cname); }

# Given a delimited sequence: open expr (punct expr)* close
# Convert it into the appropriate thing, depending on the specific open & close used.
# If the open/close are `simple' delimiters and there is only one expr,
# simply add open/close attributes.
sub Fence {
  my(@stuff)=@_;
  # Peak at delimiters to guess what kind of construct this is.
  my ($open,$close) = ($stuff[0],$stuff[$#stuff]);
  $open  = getTokenContent($open)  if ref $open;
  $close = getTokenContent($close) if ref $close;
  my $key = $open.'@'.$close;
  my $n = int(scalar(@stuff)-2+1)/2;
  my $op = ($n==1
	    ?  ($enclose1{$key} || 'Fenced')
	    : ($n==2 
	      ? ($enclose2{$key} || 'Collection')
	       : ($encloseN{$key} || 'Collection')));
  if(($n==1) && ($op eq 'Fenced')){ # Simple case.
    my $node = $stuff[1];
    $node->setAttribute(open=>$open) if $open;
    $node->setAttribute(close=>$close) if $close;
    $node; }
  else {
    ApplyDelimited(New($op,undef,role=>'FENCED'),@stuff); }}

# NOTE: It might be best to separate the multiple Formulae into separate XMath's???
# but only at the top level!
sub NewFormulae {
  my(@stuff)=@_;
  if(scalar(@stuff)==1){ $stuff[0]; }
  else { 
    my ($seps,@formula)=extract_separators(@stuff);
    Apply(New('Formulae',undef, separators=>$seps),@formula);}}

# A Formula is an alternation of expr (relationalop expr)*
# It presumably would be equivalent to (expr1 relop1 expr2) AND (expr2 relop2 expr3) ...
# But, I haven't figured out the ideal prefix form that can easily be converted to presentation.
sub NewFormula {
  my(@args)=@_;
  my $n = scalar(@args);
  if   ($n == 1){ $args[0];}
  elsif($n == 3){ Apply($args[1],$args[0],$args[2]); }
  else          { Apply(New('MultiRelation'),@args); }}

sub NewCollection {
  my(@stuff)=@_;
  if(@stuff == 1){ $stuff[0]; }
  else {
    my ($seps,@items)=extract_separators(@stuff);
    Apply(New('Collection',undef, separators=>$seps, role=>'FENCED'),@items);}}

# Given alternation of expr (addop expr)*, compose the tree (left recursive),
# flattenning portions that have the same operator
# ie. a + b + c - d  =>  (- (+ a b c) d)
sub LeftRec {
  my($arg1,@more)=@_;
  if(@more){
    my $op = shift(@more);
    my $opname = getTokenMeaning($op);
    my @args = ($arg1,shift(@more));
    while(@more && ($opname eq getTokenMeaning($more[0]))){
      shift(@more);
      push(@args,shift(@more)); }
    LeftRec(Apply($op,@args),@more); }
  else {
    $arg1; }}

# Like apply, but if ops in $arg1 (but NOT $arg2) are the same, then combine as nary.
sub ApplyNary {
  my($op,$arg1,$arg2)=@_;
  my $opname = getTokenMeaning($op);  
  my @args = ();
  if($arg1->localname eq 'XMApp'){
    my($op1,@args1)=element_nodes($arg1);
    if((getTokenMeaning($op1) eq $opname)
       && !grep($_ ,map(($op->getAttribute($_)||'<none>') ne ($op1->getAttribute($_)||'<none>'),
			qw(style)))) { # Check ops are used in similar way
      push(@args,@args1); }
    else {
      push(@args,$arg1); }}
  else {
    push(@args,$arg1); }
  push(@args,$arg2); 
  Apply($op,@args); }

# ================================================================================
# Construct an appropriate application of sub/superscripts
# $postsub & $postsuper are POSTSUBSCRIPT and POSTSUPERSCRIPT objects
# (ie. an XMApp with the script as 1st arg).
sub NewScripts {
  my($base,$postsub,$postsup,$presub,$presup)=@_;
  if($presub||$presup){
    # NOTE: Stupid arrangement for sideset!!! Fix this!!
    Apply(New('sideset'),
	  ($presub  ? Arg($presub,0)  : New('Empty')),
	  ($presup  ? Arg($presup,0)  : New('Empty')),
	  ($postsub ? Arg($postsub,0) : New('Empty')),
	  ($postsup ? Arg($postsup,0) : New('Empty')),
	  $base); }
  elsif($postsub && $postsup){
    Apply(New(undef,undef,role=>'SUBSUPERSCRIPTOP'),$base,Arg($postsub,0),Arg($postsup,0)); }
  elsif($postsub){
    Apply(New(undef,undef, role=>'SUBSCRIPTOP'),$base,Arg($postsub,0)); }
  elsif($postsup){
    Apply(New(undef,undef, role=>'SUPERSCRIPTOP'),$base,Arg($postsup,0)); }}

# ================================================================================
sub Problem { Warn("MATH Problem? ",@_); }

# Note that an UNKNOWN token may have been used as a function.
# For simplicity in the grammar, we accept a token that has sub|super scripts applied.
sub MaybeFunction {
  my($token)=@_;
  my $self = $LaTeXML::MathParser::PARSER;
  while($token->localname eq 'XMApp'){
    $token = Arg($token,1); }
  my $name = token_prettyname($token);
  $token->setAttribute('possibleFunction','yes');
  $$self{maybe_functions}{$name}++ 
    unless !$LaTeXML::MathParser::STRICT or   $$self{suspicious_tokens}{$token};
  $$self{suspicious_tokens}{$token}=1; }

# ================================================================================
1;

__END__

=pod 

=head1 NAME

C<LaTeXML::MathParser> - parses mathematics content

=head1 DESCRIPTION

C<LaTeXML::MathParser> parses the mathematical content of a document.
It uses L<Parse::RecDescent> and a grammar C<MathGrammar>.

=head2 Math Representation

Needs description.

=head2 Possibile Customizations

Needs description.

=head2 Convenience functions

The following functions are exported for convenience in writing the
grammar productions.

=over 4

=item C<< $node = New($name,$content,%attributes); >>

Creates a new C<XMTok> node with given C<$name> (a string or undef),
and C<$content> (a string or undef) (but at least one of name or content should be provided),
and attributes.

=item C<< $node = Arg($node,$n); >>

Returns the C<$n>-th argument of an C<XMApp> node;
0 is the operator node.

=item C<< Annotate($node,%attributes); >>

Add attributes to C<$node>.

=item C<< $node = Apply($op,@args); >>

Create a new C<XMApp> node representing the application of the node
C<$op> to the nodes C<@args>.

=item C<< $node = ApplyDelimited($op,@stuff); >>

Create a new C<XMApp> node representing the application of the node
C<$op> to the arguments found in C<@stuff>.  C<@stuff> are 
delimited arguments in the sense that the leading and trailing nodes
should represent open and close delimiters and the arguments are
seperated by punctuation nodes.  The text of these delimiters and
punctuation are used to annotate the operator node with
C<argopen>, C<argclose> and C<separator> attributes.

=item C<< $node = recApply(@ops,$arg); >>

Given a sequence of operators and an argument, forms the nested
application C<op(op(...(arg)))>>.

=item C<< $node = InvisibleTimes; >>

Creates an invisible times operator.

=item C<< $boole = isMatchingClose($open,$close); >>

Checks whether C<$open> and C<$close> form a `normal' pair of
delimiters, or if either is ".".

=item C<< $node=>Fence(@stuff); >>

Given a delimited sequence of nodes, starting and ending with open/close delimiters,
and with intermediate nodes separated by punctuation or such, attempt to guess what
type of thing is represented such as a set, absolute value, interval, and so on.
If nothing specific is recognized, creates the application of C<FENCED> to the arguments.

This would be a good candidate for customization!

=item C<< $node = NewFormulae(@stuff); >>

Given a set of formulas, construct a C<Formulae> application, if there are more than one,
else just return the first.

=item C<< $node = NewCollection(@stuff); >>

Given a set of expressions, construct a C<Collection> application, if there are more than one,
else just return the first.

=item C<< $node = LeftRec($arg1,@more); >>

Given an expr followed by repeated (op expr), compose the left recursive tree.
For example C<a + b + c - d> would give C<(- (+ a b c) d)>>

=item C<< $node = NewScripts($base, $postsub, $postsup, $presub, $presup); >>

Given a base and collection of following and/or preceding sub and/or superscripts
(any of which may be undef), construct an appropriate sub or superscript application.

=item C<< Problem($text); >>

Warn of a potential math parsing problem.

=item C<< MaybeFunction($token); >>

Note the possible use of C<$token> as a function, which may cause incorrect parsing.
This is used to generate warning messages.

=back

=head1 AUTHOR

Bruce Miller <bruce.miller@nist.gov>

=head1 COPYRIGHT

Public domain software, produced as part of work done by the
United States Government & not subject to copyright in the US.

=cut

