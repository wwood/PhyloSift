package Phylosift::MarkerAlign;
use Cwd;
use warnings;
use strict;
use Getopt::Long;
use Bio::AlignIO;
use Bio::SearchIO;
use Bio::SeqIO;
use List::Util qw(min);
use Carp;
use Phylosift::Phylosift;
use Phylosift::Utilities qw(:all);

=head1 NAME

Phylosift::MarkerAlign - Subroutines to align reads to marker HMMs

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

=head1 SYNOPSIS

Run HMMalign for a list of families from .candidate files located in $workingDir/PS_temp/Blast_run/


input : Filename containing the marker list


output : An alignment file for each marker listed in the input file

Option : -threaded = #    Runs Hmmalign using multiple processors.


Perhaps a little code snippet.

    use Phylosift::Phylosift;

    my $foo = Phylosift::Phylosift->new();
    ...

=head1 EXPORT

A list of functions that can be exported.  You can delete this section
if you don't export anything, such as for a purely object-oriented module.

=head1 SUBROUTINES/METHODS

=head2 MarkerAlign

=cut

my $minAlignedResidues = 20;

sub MarkerAlign {
	my %args       = @_;
	my $self       = $args{self} || miss("self");
	my $markersRef = $args{marker_reference} || miss("marker_reference");
	my @allmarkers = @{$markersRef};
	debug "beforeDirprepClean @{$markersRef}\n";
	directoryPrepAndClean( self => $self, marker_reference => $markersRef );
	debug "AFTERdirprepclean @{$markersRef}\n";
	my $index = -1;
	markerPrepAndRun( self => $self, marker_reference => $markersRef );
	debug "after HMMSEARCH PARSE\n";
	alignAndMask( self => $self, marker_reference => $markersRef );
	debug "AFTER ALIGN and MASK\n";

	# produce a concatenate alignment for the base marker package
	unless ( $self->{"extended"} ) {
		my @markeralignments = getPMPROKMarkerAlignmentFiles( self => $self, marker_reference => \@allmarkers );
		my $outputFastaAA = $self->{"alignDir"} . "/" . Phylosift::Utilities::get_aligner_output_fasta_AA( marker => "concat" );
		Phylosift::Utilities::concatenate_alignments(
													  self           => $self,
													  output_fasta   => $outputFastaAA,
													  output_bayes   => $self->{"alignDir"} . "/mrbayes.nex",
													  gap_multiplier => 1,
													  alignments     => \@markeralignments
		);

		# now concatenate any DNA alignments
		for ( my $i = 0 ; $i < @markeralignments ; $i++ ) {
			$markeralignments[$i] =~ s/trim.fasta/trim.fna.fasta/g;
		}
		my $outputFastaDNA = $self->{"alignDir"} . "/" . Phylosift::Utilities::get_aligner_output_fasta_DNA( marker => "concat" );
		Phylosift::Utilities::concatenate_alignments(
													  self           => $self,
													  output_fasta   => $outputFastaDNA,
													  output_bayes   => $self->{"alignDir"} . "/mrbayes-dna.nex",
													  gap_multiplier => 3,
													  alignments     => \@markeralignments
		);


		# produce a concatenate with 16s + DNA alignments
		for ( my $i = 0 ; $i < @markeralignments ; $i++ ) {
			$markeralignments[$i] =~ s/trim.fasta/trim.fna.fasta/g;
		}
		push( @markeralignments, $self->{"alignDir"} . "/" . Phylosift::Utilities::get_aligner_output_fasta_AA( marker => "16s_reps_bac" ) );
		push( @markeralignments, $self->{"alignDir"} . "/" . Phylosift::Utilities::get_aligner_output_fasta_AA( marker => "16s_reps_arc" ) );
		push( @markeralignments, $self->{"alignDir"} . "/" . Phylosift::Utilities::get_aligner_output_fasta_AA( marker => "18s_reps" ) );
		$outputFastaDNA = $self->{"alignDir"} . "/" . Phylosift::Utilities::get_aligner_output_fasta_DNA( marker => "concat16" );
		Phylosift::Utilities::concatenate_alignments(
													  self           => $self,
													  output_fasta   => $outputFastaDNA,
													  output_bayes   => $self->{"alignDir"} . "/mrbayes-dna16.nex",
													  gap_multiplier => 3,
													  alignments     => \@markeralignments
		);
		debug "AFTER concatenateALI\n";
	}
	return $self;
}

=head2 directoryPrepAndClean

=cut

sub directoryPrepAndClean {
	my %args    = @_;
	my $self    = $args{self} || miss("self");
	my $markRef = $args{marker_reference} || miss("marker_reference");

	#create a directory for the Reads file being processed.
	`mkdir -p $self->{"fileDir"}`;
	`mkdir -p $self->{"alignDir"}`;
	for ( my $index = 0 ; $index < @{$markRef} ; $index++ ) {
		my $marker = ${$markRef}[$index];
		my $candidate_file = Phylosift::Utilities::get_candidate_file( self => $self, marker => $marker, type => "" );
		if ( -z $candidate_file ) {
			warn "WARNING : the candidate file for $marker is empty\n";
			splice @{$markRef}, $index--, 1;
			next;
		}
	}
	return $self;
}
my @search_types = ( "", ".lastal" );
my @search_types_rna = ( "", ".lastal.rna", ".rna" );

sub split_rna_on_size {
	my %args      = @_;
	my $in_fasta  = $args{in_file} || miss("in_file");
	my $short_out = $args{short_out} || miss("short_out");
	my $long_out  = $args{long_out} || miss("long_out");
	my $LONG_OUT;
	my $SHORT_OUT;
	my $seq_in = Phylosift::Utilities::open_SeqIO_object( file => $in_fasta );
	while ( my $seq = $seq_in->next_seq ) {
		my $OUT;
		if ( $seq->length > 500 ) {
			$LONG_OUT = ps_open( ">>" . $long_out ) unless defined $LONG_OUT && fileno $LONG_OUT;
			$OUT = $LONG_OUT;
		} else {
			$SHORT_OUT = ps_open( ">>" . $short_out ) unless defined $SHORT_OUT && fileno $SHORT_OUT;
			$OUT = $SHORT_OUT;
		}
		print $OUT ">" . $seq->id . "\n" . $seq->seq . "\n";
	}
}

=cut

=head2 markerPrepAndRun

=cut

sub markerPrepAndRun {
	my %args    = @_;
	my $self    = $args{self} || miss("self");
	my $markRef = $args{marker_reference} || miss("marker_reference");
	debug "ALIGNDIR : " . $self->{"alignDir"} . "\n";
	foreach my $marker ( @{$markRef} ) {
		unless ( Phylosift::Utilities::is_protein_marker( marker => $marker ) ) {

			# separate RNA candidates by size
			my $candidate_long  = Phylosift::Utilities::get_candidate_file( self => $self, marker => $marker, type => ".rna.long" );
			my $candidate_short = Phylosift::Utilities::get_candidate_file( self => $self, marker => $marker, type => ".rna.short" );
			unlink($candidate_long);
			unlink($candidate_short);
			foreach my $type (@search_types_rna) {
				my $candidate = Phylosift::Utilities::get_candidate_file( self => $self, marker => $marker, type => $type );
				my @candidate_files = <$candidate.*>;
				foreach my $cand_file (@candidate_files) {
					split_rna_on_size( in_file => $cand_file, short_out => $candidate_short, long_out => $candidate_long );
				}
			}
			next;
		}
		my $hmm_file = Phylosift::Utilities::get_marker_hmm_file( self => $self, marker => $marker, loc => 1 );
		my $stockholm_file = Phylosift::Utilities::get_marker_stockholm_file( self => $self, marker => $marker );
		unless ( -e $hmm_file && -e $stockholm_file ) {
			my $trimfinalFile = Phylosift::Utilities::get_trimfinal_marker_file( self => $self, marker => $marker );

			#converting the marker's reference alignments from Fasta to Stockholm (required by Hmmer3)
			Phylosift::Utilities::fasta2stockholm( fasta => "$trimfinalFile", output => $stockholm_file );

			#build the Hmm for the marker using Hmmer3
			if ( !-e $hmm_file ) {
				`$Phylosift::Utilities::hmmbuild $hmm_file $stockholm_file`;
			}
		}
		my $new_candidate = Phylosift::Utilities::get_candidate_file( self => $self, marker => $marker, type => "", new => 1 );
		unlink($new_candidate);
		foreach my $type (@search_types) {
			my $candidate = Phylosift::Utilities::get_candidate_file( self => $self, marker => $marker, type => $type );
			my @candidate_files = <$candidate.*>;
			foreach my $cand_file (@candidate_files) {
				next unless -e $cand_file;
				my $fifo_out = $self->{"alignDir"} . "/" . Phylosift::Utilities::get_marker_basename( marker => $marker ) . ".tmpout.fifo";
				`mkfifo $fifo_out`;
				system( "$Phylosift::Utilities::hmmsearch -E 10 --cpu " . $self->{"threads"} . " --max --tblout $fifo_out $hmm_file $cand_file > /dev/null &" );
				my $HMMSEARCH = ps_open($fifo_out);
				hmmsearch_parse( self => $self, marker => $marker, type => $type, HMMSEARCH => $HMMSEARCH, fasta_file => $cand_file );
				unlink($fifo_out);
			}
		}
	}
	return $self;
}

=head2 hmmsearchParse

=cut

sub hmmsearch_parse {
	my %args       = @_;
	my $self       = $args{self} || miss("self");
	my $marker     = $args{marker} || miss("marker");
	my $type       = $args{type} || miss("type");
	my $HMMSEARCH  = $args{HMMSEARCH} || miss("HMMSEARCH");
	my $fasta_file = $args{fasta_file} || miss("fasta file");
	my %hmmHits    = ();
	my %hmmScores  = ();
	my $countHits  = 0;
	while (<$HMMSEARCH>) {
		chomp($_);
		if ( $_ =~ m/^(\S+)\s+-\s+(\S+)\s+-\s+(\S+)\s+(\S+)/ ) {
			$countHits++;
			my $hitname     = $1;
			my $basehitname = $1;
			my $hitscore    = $4;
			if ( !defined( $hmmScores{$basehitname} ) || $hmmScores{$basehitname} < $hitscore ) {
				$hmmScores{$basehitname} = $hitscore;
				$hmmHits{$basehitname}   = $hitname;
			}
		}
	}
	my $new_candidate = Phylosift::Utilities::get_candidate_file( self => $self, marker => $marker, type => "", new => 1 );
	$new_candidate = ">" . $new_candidate if -f $new_candidate;    # append if the file already exists
	$new_candidate = ">" . $new_candidate;                         # otherwise make a new one
	my $NEWCANDIDATE = ps_open($new_candidate);
	my $seqin = Phylosift::Utilities::open_SeqIO_object( file => $fasta_file );
	while ( my $sequence = $seqin->next_seq ) {
		my $baseid = $sequence->id;
		if ( exists $hmmHits{$baseid} && $hmmHits{$baseid} eq $sequence->id ) {
			print $NEWCANDIDATE ">" . $sequence->id . "\n" . $sequence->seq . "\n";
		}
	}
	close($NEWCANDIDATE);
}

=head2 writeAlignedSeq

=cut

sub writeAlignedSeq {
	my %args        = @_;
	my $self        = $args{self} || miss("self");
	my $OUTPUT      = $args{OUTPUT};
	my $UNMASKEDOUT = $args{UNMASKED_OUT};
	my $prev_name   = $args{prev_name} || miss("prev_name");
	my $prev_seq    = $args{prev_seq} || miss("prev_seq");
	my $seq_count   = $args{seq_count};
	my $orig_seq    = $prev_seq;
	$prev_seq =~ s/[a-z]//g;    # lowercase chars didnt align to model
	$prev_seq =~ s/\.//g;       # shouldnt be any dots
	                            #skip paralogs if we don't want them
	return if $seq_count > 0 && $self->{"besthit"};
	my $aligned_count = 0;
	$aligned_count++ while $prev_seq =~ m/[A-Z]/g;
	return if $aligned_count < $minAlignedResidues;

	#substitute all the non letter or number characters into _ in the IDs to avoid parsing issues in tree viewing programs or others
	$prev_name = Phylosift::Summarize::tree_name( name => $prev_name );

	#add a paralog ID if we're running in isolate mode and more than one good hit
	#$prev_name .= "_p$seq_count" if $seq_count > 0 && $self->{"isolate"};
	#print the new trimmed alignment
	print $OUTPUT ">$prev_name\n$prev_seq\n"      if defined($OUTPUT);
	print $UNMASKEDOUT ">$prev_name\n$orig_seq\n" if defined($UNMASKEDOUT);
}
use constant CODONSIZE => 3;
my $GAP      = '-';
my $CODONGAP = $GAP x CODONSIZE;

=head2 aa_to_dna_aln
Function based on BioPerl's aa_to_dna_aln. This one has been modified to preserve . characters and upper/lower casing of the protein
sequence during reverse translation. Needed to mask out HMM aligned sequences.
=cut

sub aa_to_dna_aln {
	my %args = @_;
	my ( $aln, $dnaseqs ) = ( $args{aln}, $args{dna_seqs} );
	unless (    defined $aln
			 && ref($aln)
			 && $aln->isa('Bio::Align::AlignI') )
	{
		croak(
'Must provide a valid Bio::Align::AlignI object as the first argument to aa_to_dna_aln, see the documentation for proper usage and the method signature' );
	}
	my $alnlen   = $aln->length;
	my $dnaalign = Bio::SimpleAlign->new();
	foreach my $seq ( $aln->each_seq ) {
		my $aa_seqstr    = $seq->seq();
		my $id           = $seq->display_id;
		my $dnaseq       = $dnaseqs->{$id} || $aln->throw( "cannot find " . $seq->display_id );
		my $start_offset = ( $seq->start - 1 ) * CODONSIZE;
		$dnaseq = $dnaseq->seq();
		my $dnalen = $dnaseqs->{$id}->length;
		my $nt_seqstr;
		my $j = 0;

		for ( my $i = 0 ; $i < $alnlen ; $i++ ) {
			my $char = substr( $aa_seqstr, $i + $start_offset, 1 );
			if ( $char eq $GAP ) {
				$nt_seqstr .= $CODONGAP;
			} elsif ( $char eq "." ) {
				$nt_seqstr .= "...";
			} else {
				if ( length $dnaseq >= $j + CODONSIZE ) {
					if ( $char eq uc($char) ) {
						$nt_seqstr .= uc( substr( $dnaseq, $j, CODONSIZE ) );
					} else {
						$nt_seqstr .= lc( substr( $dnaseq, $j, CODONSIZE ) );
					}
				}
				$j += CODONSIZE;
			}
		}
		$nt_seqstr .= $GAP x ( ( $alnlen * 3 ) - length($nt_seqstr) );
		my $newdna = Bio::LocatableSeq->new(
											 -display_id    => $id,
											 -alphabet      => 'dna',
											 -start         => 1,
											 -end           => length($nt_seqstr),
											 -strand        => 1,
											 -seq           => $nt_seqstr,
											 -verbose       => -1,
											 -nowarnonempty => 1
		);
		$dnaalign->add_seq($newdna);
	}
	return $dnaalign;
}

=head2 alignAndMask

=cut 

sub alignAndMask {
	my %args    = @_;
	my $self    = $args{self} || miss("self");
	my $markRef = $args{marker_reference} || miss("marker_reference");
	for ( my $index = 0 ; $index < @{$markRef} ; $index++ ) {
		my $marker         = ${$markRef}[$index];
		my $refcount       = 0;
		my $stockholm_file = Phylosift::Utilities::get_marker_stockholm_file( self => $self, marker => $marker );
		my $hmmalign       = "";
		my @lines;
		if ( Phylosift::Utilities::is_protein_marker( marker => $marker ) ) {
			my $new_candidate = Phylosift::Utilities::get_candidate_file( self => $self, marker => $marker, type => "", new => 1 );
			next unless -e $new_candidate && -s $new_candidate > 0;
			my $hmm_file = Phylosift::Utilities::get_marker_hmm_file( self => $self, marker => $marker, loc => 1 );
			my $HMM = ps_open($hmm_file);
			while ( my $line = <$HMM> ) {
				if ( $line =~ /NSEQ\s+(\d+)/ ) {
					$refcount = $1;
					last;
				}
			}

			# Align the hits to the reference alignment using Hmmer3
			# pipe in the aligned sequences, trim them further, and write them back out
			$hmmalign = "$Phylosift::Utilities::hmmalign --outformat afa --mapali " . $stockholm_file . " $hmm_file $new_candidate |";
			debug "Running $hmmalign\n";
			my $HMMALIGN = ps_open($hmmalign);
			@lines = <$HMMALIGN>;
		} else {
			debug "Setting up cmalign for marker $marker\n";
			my $candidate_long  = Phylosift::Utilities::get_candidate_file( self => $self, marker => $marker, type => ".rna.long" );
			my $candidate_short = Phylosift::Utilities::get_candidate_file( self => $self, marker => $marker, type => ".rna.short" );

			#if the marker is rna, use infernal instead of hmmalign
			# use tau=1e-6 instead of default 1e-7 to reduce memory consumption to under 4GB
			my $fasta = "";
			if ( -e $candidate_long ) {
				my $cmalign =
				    "$Phylosift::Utilities::cmalign -q --dna --tau 1e-6 "
				  . Phylosift::Utilities::get_marker_cm_file( self => $self, marker => $marker )
				  . " $candidate_long | ";
				debug "Running $cmalign\n";
				my $CMALIGN = ps_open($cmalign);
				$fasta .= Phylosift::Utilities::stockholm2fasta( in => $CMALIGN );
			}
			if ( -e $candidate_short ) {
				my $cmalign =
				    "$Phylosift::Utilities::cmalign -q -l --dna --tau 1e-20 "
				  . Phylosift::Utilities::get_marker_cm_file( self => $self, marker => $marker )
				  . " $candidate_short | ";
				debug "Running $cmalign\n";
				my $CMALIGN = ps_open($cmalign);
				$fasta .= Phylosift::Utilities::stockholm2fasta( in => $CMALIGN );
			}
			@lines = split( /\n/, $fasta );
			next if @lines == 0;
		}
		my $outputFastaAA = $self->{"alignDir"} . "/" . Phylosift::Utilities::get_aligner_output_fasta_AA( marker => $marker );
		my $outputFastaDNA = $self->{"alignDir"} . "/" . Phylosift::Utilities::get_aligner_output_fasta_DNA( marker => $marker );
		my $mbname = Phylosift::Utilities::get_marker_basename( marker => $marker );
		my $ALIOUT = ps_open( ">" . $outputFastaAA );
		my $prev_seq;
		my $prev_name;
		my $seqCount    = 0;
		my $UNMASKEDOUT = ps_open( ">" . $self->{"alignDir"} . "/$mbname.unmasked" );

		foreach my $line (@lines) {
			chomp $line;
			if ( $line =~ /^>(.+)/ ) {
				my $new_name = $1;
				writeAlignedSeq(
								 self      => $self,
								 prev_name => $prev_name,
								 prev_seq  => $prev_seq,
								 seq_count => 0
				  )
				  if $seqCount <= $refcount
					  && $seqCount > 0;
				writeAlignedSeq(
								 self         => $self,
								 OUTPUT       => $ALIOUT,
								 UNMASKED_OUT => $UNMASKEDOUT,
								 prev_name    => $prev_name,
								 prev_seq     => $prev_seq,
								 seq_count    => $seqCount - $refcount - 1
				) if $seqCount > $refcount && $seqCount > 0;
				$seqCount++;
				$prev_name = $new_name;
				$prev_seq  = "";
			} else {
				$prev_seq .= $line;
			}
		}
		writeAlignedSeq( self => $self, prev_name => $prev_name, prev_seq => $prev_seq, seq_count => 0 )
		  if $seqCount <= $refcount && $seqCount > 0;
		writeAlignedSeq(
						 self         => $self,
						 OUTPUT       => $ALIOUT,
						 UNMASKED_OUT => $UNMASKEDOUT,
						 prev_name    => $prev_name,
						 prev_seq     => $prev_seq,
						 seq_count    => $seqCount - $refcount - 1
		) if $seqCount > $refcount;
		$seqCount -= $refcount;
		close $UNMASKEDOUT;
		close $ALIOUT;

		my $type = Phylosift::Utilities::get_sequence_input_type( $self->{"readsFile"} );
		if($type->{seqtype} ne "protein" && Phylosift::Utilities::is_protein_marker( marker => $marker ) ){
			# do we need to output a nucleotide alignment in addition to the AA alignment?
			my %referenceNuc    = (); # this will collect all the nucleotide seqs for the marker by name
			foreach my $type (@search_types) {
	
				#if it exists read the reference nucleotide sequences for the candidates
				my $core_file_name  = Phylosift::Utilities::get_candidate_file( self => $self, marker => $marker, type => $type, dna => 1 );
				my @candidate_files = <$core_file_name.*>;
				foreach my $cand_file (@candidate_files) {
					if ( -e $cand_file && -e $outputFastaAA ) {
						my $REFSEQSIN = ps_open($cand_file);
						my $currID    = "";
						my $currSeq   = "";
						while ( my $line = <$REFSEQSIN> ) {
							chomp($line);
							if ( $line =~ m/^>(.*)/ ) {
								$currID = $1;
							} else {
								my $tempseq = Bio::PrimarySeq->new( -seq => $line, -id => $currID, -nowarnonempty => 1 );
								$referenceNuc{$currID} = $tempseq;
							}
						}
						close($REFSEQSIN);
					}
				}
			}
			my $ALITRANSOUT = ps_open( ">>" . $outputFastaDNA );
			if ( $self->{"extended"} ) {
				$marker =~ s/^\d+\///g;
			}
			debug "MARKER : $marker\n";
			my $aa_ali = new Bio::AlignIO( -file => $self->{"alignDir"} . "/$marker.unmasked", -format => 'fasta' );
			if ( my $aln = $aa_ali->next_aln() ) {
				my $dna_ali = &aa_to_dna_aln( aln => $aln, dna_seqs => \%referenceNuc );
				foreach my $seq ( $dna_ali->each_seq() ) {
					my $cleanseq = $seq->seq;
					$cleanseq =~ s/\.//g;
					$cleanseq =~ s/[a-z]//g;
					print $ALITRANSOUT ">" . $seq->id . "\n" . $cleanseq . "\n";
				}
			}
			close($ALITRANSOUT);
			
		}

		#checking if sequences were written to the marker alignment file
		if ( $seqCount == 0 ) {

			#removing the marker from the list if no sequences were added to the alignment file
			warn "Masking or hmmsearch thresholds failed, removing $marker from the list\n";
			splice @{$markRef}, $index--, 1;
		}

		# check alignments so it merges sequences in case of paired end reads
		if ( $self->{"readsFile_2"} ne "" ) {
			merge_alignment( alignment_file => $self->{"alignDir"} . "/$mbname.unmasked", type => 'AA' );
			merge_alignment( alignment_file => $outputFastaAA,                            type => 'AA' );
			if( Phylosift::Utilities::is_protein_marker( marker => $marker ) ){
				merge_alignment( alignment_file => $outputFastaDNA,                           type => 'DNA' );
			}
		}
		# get rid of the process IDs -- they break concatenation
		strip_trailing_ids(alignment_file=>$outputFastaAA);
		if( Phylosift::Utilities::is_protein_marker( marker => $marker ) ){
			strip_trailing_ids(alignment_file=>$outputFastaDNA);
		}
	}
}

sub strip_trailing_ids {
	my %args = @_;
	my $ali_file = $args{alignment_file};
	my $ALI_IN = ps_open($ali_file);
	my @ali = <$ALI_IN>;
	my $ALI_OUT = ps_open(">".$ali_file);
	foreach my $line (@ali){
		chomp $line;
		if($line =~ /^>/){
			$line =~ s/_\d+$//g;
		}
		print $ALI_OUT "$line\n";
	}
}

=head2 merge_alignment

merge alignments by combining sequences from paired end reads.
If aligned columns do not match an X will be used for amino acids and a N will be used for nucleotides
if a residue will always win over a gap
=cut

sub merge_alignment {
	my %args     = @_;
	my $ali_file = $args{alignment_file};
	my $type     = $args{type};
	my %seqs     = ();
	my $seq_IO   = Phylosift::Utilities::open_SeqIO_object( file => $ali_file );
	while ( my $seq = $seq_IO->next_seq() ) {
		$seq->id =~ m/^(\S+)(\d+)$/;
		my $core = $1;

		#debug "Comparing " . $seq->id . " with " . $core . "\n";
		if ( exists $seqs{$core} ) {
			my @seq1 = split( //, $seqs{$core} );
			my @seq2 = split( //, $seq->seq );
			my $result_seq = "";
			for ( my $i = 0 ; $i < length( $seqs{$core} ) ; $i++ ) {
				if ( $seq1[$i] eq $seq2[$i] ) {
					$result_seq .= $seq1[$i];
				} elsif ( $seq1[$i] =~ /[a-z]/ && $seq2[$i] =~ m/[a-z]/ && $seq1[$i] ne $seq2[$i] ) {
					$result_seq .= $type eq 'AA' ? 'x' : 'n';
				} elsif ( $seq1[$i] =~ /[A-Z]/ && $seq2[$i] =~ m/[A-Z]/ && $seq1[$i] ne $seq2[$i] ) {
					$result_seq .= $type eq 'AA' ? 'X' : 'N';
				} elsif ( $seq1[$i] =~ /[-\.]/ && $seq2[$i] =~ m/[A-Za-z]/ ) {
					$result_seq .= $seq2[$i];
				} elsif ( $seq1[$i] =~ m/[A-Za-z]/ && $seq2[$i] =~ /[-\.]/ ) {
					$result_seq .= $seq1[$i];
				} else {
					debug "FOUND A SPECIAL CASE $seq1[$i] $seq2[$i]\n";
				}
			}
			$seqs{$core} = $result_seq;
		} else {
			$seqs{$core} = $seq->seq;
		}
	}

	#print to the alignment file
	my $FH = ps_open( ">" . $ali_file );
	foreach my $core ( keys %seqs ) {
		print $FH ">" . $core . "\n" . $seqs{$core} . "\n";
	}
	close($FH);
}

sub getPMPROKMarkerAlignmentFiles {
	my %args             = @_;
	my $self             = $args{self} || miss("self");
	my $markRef          = $args{marker_reference} || miss("marker_reference");
	my @markeralignments = ();
	foreach my $marker ( @{$markRef} ) {
		next unless $marker =~ /PMPROK/;
		push( @markeralignments, $self->{"alignDir"} . "/" . Phylosift::Utilities::get_aligner_output_fasta_AA( marker => $marker ) );
	}
	return @markeralignments;
}

=head1 AUTHOR

Aaron Darling, C<< <aarondarling at ucdavis.edu> >>
Guillaume Jospin, C<< <gjospin at ucdavis.edu> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-phylosift-phylosift at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Phylosift-Phylosift>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.




=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Phylosift::Phylosift


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker (report bugs here)

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Phylosift-Phylosift>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Phylosift-Phylosift>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Phylosift-Phylosift>

=item * Search CPAN

L<http://search.cpan.org/dist/Phylosift-Phylosift/>

=back


=head1 ACKNOWLEDGEMENTS


=head1 LICENSE AND COPYRIGHT

Copyright 2011 Aaron Darling and Guillaume Jospin.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation.

See http://dev.perl.org/licenses/ for more information.


=cut

1;    # End of Phylosift::MarkerAlign.pm
