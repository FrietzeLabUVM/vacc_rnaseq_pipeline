#!/bin/bash
#SLURM pipeline for RNAseq

export PATH=/gpfs2/pi-sfrietze/bin:$PATH

SCRIPTS=$(dirname "$(readlink -f "$0")")

mode=PE
sub_mode=sbatch
# umask 077 # rw permission for user only
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -f1|--fastq1) F1="$2"; shift ;;
        -f2|--fastq2) F2="$2"; shift ;;
        -f1s|--f1_suffix) F1_suff="$2"; shift ;;
        -f2s|--f2_suffix) F2_suff="$2"; shift ;;
        -i|--inDir) in_path="$2"; shift ;;
        -p|--outPrefix) root="$2"; echo root is $root; shift ;;
        -o|--outDir) align_path="$2"; shift ;;
        -ref|--reference) ref=$2; shift ;;
        -idx|--starIndex) star_index="$2"; shift ;;
        -s|--suppaRef) suppa_ref="$2"; shift ;; 
        -g|--gtf) gtf="$2"; shift ;;
        -fa|--fasta) fasta="$2"; shift ;;
        -rDNA|--rDNA_starIndex) rDNA_index="$2"; shift ;;
        -SE|--SE) mode=SE ;;
        -noSub|--noSub) sub_mode=bash ;;
        -sl|--scriptLocation) SCRIPTS="$2"; shift ;;
        -h|--help) cat $SCRIPTS/help_msg.txt; exit 0; shift ;;
        *) echo "Unknown parameter passed: $1"; cat $SCRIPTS/help_msg.txt; exit 1 ;;
    esac
    shift
done

if [ ! -d $SCRIPTS ]; then echo could not find script directory $SCRIPTS, quit!; exit 1; fi
#if [ -z $ref ]; then echo need star index location for -idx; exit 1; fi
if [ -z $F1 ]; then echo need fastq1 as -f1! quit; exit 1; fi
if [ ! -z $in_path ]; then F1=${in_path}/${F1}; fi
F1=${F1//"&"/" "}
for f in $F1; do if [ ! -f $f ]; then echo fastq1 $f could not be found! quit; exit 1; fi; done
#if [ -z $gtf ]; then echo need gtf as -g; exit 1; fi
#if [ -z $fasta]; then echo need reference fasta as -fa; exit 1; fi
#if [ -z $align_path ]; then echo need alignment output path as -o; exit 1; fi

#relevant suffixes
if [ -z $F1_suff ]; then F1_suff="_R1_001.fastq.gz"; fi
if [ -z $F2_suff ]; then F2_suff="_R2_001.fastq.gz"; fi
suf_gz1="$F1_suff"
suf_gz2="$F2_suff"

if [ $mode = PE ]; then
 F2=${F1//$suf_gz1/$suf_gz2}
 #check that all F2 exist
 for f in $F2; do if [ ! -f $f ]; then echo fastq2 $f could not be found! quit; exit 1; fi; done
 F1a=($F1)
 F2a=($F2)
 #check same number of F1 and F2
 if [ ${#F1a[@]} != ${#F2a[@]} ]; then
   echo Differing numbers of R1 and R2 fastqs supplied! quit
   echo $F1
   echo $F2
   exit 1
 fi
 #check that F1 and F2 are different
 i=0
 while [ $i -lt ${#F1a[@]} ]; do
   if [ ${F1a[$i]} = ${F2a[$i]} ]; then echo problem with fastq pairing. quit; exit 1; fi
    i=$(( $i + 1 ))
 done
fi

suf_out_bam=".Aligned.out.bam"
suf_tx_bam=".Aligned.toTranscriptome.out.bam"
suf_sort_bam=".Aligned.sortedByCoord.out.bam"
suf_sort_bai=".Aligned.sortedByCoord.out.bam.bai"
suf_salmon_quant=".salmon_quant"
suf_log=".Log.out"
suf_align_stats=".Log.final.out"
suf_featr_count=".Aligned.sortedByCoord.out.featureCounts.txt"

#star_index=$ref/STAR_INDEX
#suppa_ref=$ref/SUPPA2
if [ -z $star_index ]; then star_index=$ref/STAR_INDEX; echo guessing star index as $star_index; fi
if [ ! -d $star_index ]; then echo star_index $star_index not found!; exit 1; fi
if [ -z $suppa_ref ]; then suppa_ref=$ref/SUPPA2; echo guessing suppa_ref as $suppa_ref; fi
if [ ! -d $suppa_ref ]; then echo suppa_ref $suppa_ref not found!; exit 1; fi
if [ -z $gtf ]; then gtf=$(readlink -m -f $ref/GTF/current.gtf); echo guessing gtf as $gtf; fi
if [ ! -f $gtf ]; then echo gtf $gtf not found! exit; exit 1; fi
if [ -z $fasta ]; then fasta=$(readlink -m -f $ref/FASTA/genome.fa); echo guessing fasta as $fasta; fi
if [ ! -f $fasta ]; then echo fasta $fasta not found! exit; exit 1; fi
if [ -z $tx ]; then tx=$(readlink -m -f $ref/FASTA/transcriptome.fa); echo guessing transcriptome fasta as $tx; fi
if [ ! -f $tx ]; then echo transcriptome fasta $tx not found! exit; exit 1; fi
if [ -z $rDNA_index ]; then 
  rDNA_index=$(readlink -m -f ${ref}.rDNA/STAR_INDEX); echo guess rDNA star index as $rDNA_index; 
else
  #rDNA star index must exist if specified instead of guessed
  if [ ! -d $rDNA_index ]; then echo Specified rDNA star index $rDNA_index was not found! quit; fi
fi

#output locations
if [ -z $align_path ]; then align_path=~/scratch/alignment_RNA-seq; echo using default alignment output path of $align_path; fi
if [ -z $root ]; then root=$(basename $(echo $F1 | awk -v FS=" +" '{print $1}') $suf_gz1); echo guessing root prefix is $root. provide with -p if incorrect;  fi
log_path=${align_path}/${root}.logs

#all must exist
mkdir -p $align_path
mkdir -p $log_path

#important files
out_bam=${align_path}/${root}${suf_out_bam}
tx_bam=${align_path}/${root}${suf_tx_bam}
sort_bam=${align_path}/${root}${suf_sort_bam}
salmon_out=${align_path}/${root}${suf_salmon_quant}
featr_out=${align_path}/${root}${suf_featr_count}

parse_jid () { #parses the job id from output of qsub
        #echo $1
        if [ -z "$1" ]; then
        echo parse_jid expects output of qsub as first input but input was empty! stop
        exit 1
        fi
        #JOBID=$(echo $1 | awk '{print $3}') #returns JOBID
        JOBID=$(echo $1 | egrep -o -e "\b[0-9]+$")
        echo $JOBID;
}

if [ $sub_mode != "sbatch" ] && [ $sub_mode != "bash" ]; then echo sub_mode was $sub_mode, not one of sbatch or bash. quit!; exit 1; fi
if [ $sub_mode = "sbatch" ]; then 
  qsub_cmd="sbatch -o $log_path/%x.%j.out -e $log_path/%x.%j.error --export=PATH=$PATH"
elif [ $sub_mode = "bash" ]; then
  qsub_cmd="bash"
fi

$qsub_cmd $SCRIPTS/echo_submission.sh $0 $#

#align script
F1=${F1//" "/"&"}
se_mode=""

#bigwigs
bw_sub_args="-J make_bigwigs"
if [ $sub_mode = "bash" ]; then bw_sub_args=""; fi
if [ $mode = SE ]; then
  bw_qsub=$($qsub_cmd $bw_sub_args $SCRIPTS/run_bam_to_bigwig.sh -b $sort_bam -s $star_index/chrNameLength.txt -o ${sort_bam/.bam/""}.bigwigs)
else
  bw_qsub=$($qsub_cmd $bw_sub_args $SCRIPTS/run_bam_to_bigwig.sh -b $sort_bam -s $star_index/chrNameLength.txt -o ${sort_bam/.bam/""}.bigwigs -pe)
fi
bw_jid=$(parse_jid "$bw_qsub")
echo bw_jid $bw_jid
