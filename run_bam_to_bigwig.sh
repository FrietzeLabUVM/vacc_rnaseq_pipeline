#!/bin/sh
#SBATCH --mem=10000
#SBATCH -o bigwig_%j.out                 # File to which STDOUT will be written, including job ID
#SBATCH -e bigwig_%j.err                 # File to which STDERR will be written, including job ID

libType=SE

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -b|--bam) BAM="$2"; shift ;;
        -s|--chrSizes) CHR_SIZES="$2"; shift ;;
        -o|--outDir) O="$2"; shift ;;
        -pe|--pe) libType=PE ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

if [ -z $BAM ] || [ -z $CHR_SIZES ] || [ -z $O ]; then
  echo bam file \(-b\|--bam\), chrSizes file \(-s\|--chrSizes\), and output directory \(-o\|--outDir\) are all required. quit.
  exit 1
fi

if [ ! -f $BAM ]; then echo bam file $BAM not found! quit.; exit 1; fi
BAM=$(readlink -f $BAM)
echo BAM is $BAM
if [ ! -f $BAM ]; then
  echo BAM does not exist, stop.
  echo add BAM= in qsub or supply as first arg.
  exit 1
fi

if [ ! -f $CHR_SIZES ]; then echo chrSizes file $CHR_SIZES not found! quit.; exit 1; fi
CHR_SIZES=$(readlink -f $CHR_SIZES)
echo CHR_SIZES is $CHR_SIZES
if [ ! -f $CHR_SIZES ]; then
  echo CHR_SIZES does not exist, stop.
  echo add CHR_SIZES= in qsub or supply as second arg
  exit 1
fi

mkdir -p $O
O=$(readlink -f $O)

name=${BAM/.bam/""}
name=$(basename $name)
tmpdir=$O/tmp_bam2bw.${name}
mkdir $tmpdir
cd $tmpdir

#for PE need to filter for read 1
if [ libType = PE ]; then
  samtools view -hb -f 64 $BAM > read1.bam
  BAM=read1.bam
fi


F_FILE=${name}.factor
if [ -f $F_FILE ]; then
  echo skip factor calc
  FACTOR=$(cat $F_FILE)
else
  echo calc factor
  FACTOR=$(echo "scale=5; 1000000/$(samtools view -c $BAM | awk '{print $1}')" | bc)
  echo $FACTOR > $F_FILE
fi
echo FACTOR is $FACTOR

for strand in unstranded positive negative; do
for norm in raw normalized; do
for splice in show hide; do
  sdir=unstranded
  if [ $strand != unstranded ]; then sdir=stranded; fi
  bwdir=$sdir/$norm
  mkdir -p $bwdir

  strand_arg=""
  if [ $strand = positive ]; then 
    strand_arg="-strand +";
  elif [ $strand = negative ]; then
    strand_arg="-strand -";
  fi
  scale_arg=""
  if [ $norm = normalized ]; then
    scale_arg="-scale $FACTOR"
  fi
  suff=bdg
  splice_arg=""
  if [ $splice = "show" ]; then
    suff=showSplice.bdg
  else
    splice_arg="-split"
  fi
    
  BDG=$bwdir/${name}_${norm}_${strand}.${suff}
  echo make bedgraph $BDG
  cmd=""
  if [ -f $BDG ]; then echo skip $BDG, delete to rerun; else cmd="genomeCoverageBed -bg $splice_arg $scale_arg $strand_arg -ibam $BAM -g $CHR_SIZES > $BDG; bedSort $BDG $BDG"; echo $cmd; genomeCoverageBed -bg $splice_arg $scale_arg $strand_arg -ibam $BAM -g $CHR_SIZES > $BDG; bedSort $BDG $BDG; fi

  BW=${BDG/%.bdg/.bw}
  echo make bigwig $BW
  cmd2=""
  if [ -f $BW ]; then echo skip bigwig $BW, detete to rerun; else cmd2="bedGraphToBigWig $BDG $CHR_SIZES $BW"; echo $cmd2; bedGraphToBigWig $BDG $CHR_SIZES $BW; fi

  ln $BW ..
done; done; done

cd ..
echo delete $tmpdir if bigwigs look good
rm -r $tmpdir
#rm ${cell_line}_${extraction}_${replicate}_normalized.bedgraph

