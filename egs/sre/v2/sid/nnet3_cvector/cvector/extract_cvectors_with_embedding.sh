#!/bin/bash

# Copyright     2017  David Snyder
#               2017  Johns Hopkins University (Author: Daniel Povey)
#               2017  Johns Hopkins University (Author: Daniel Garcia Romero)
# Apache 2.0.

# This script extracts embeddings (called "xvectors" here) from a set of
# utterances, given features and a trained DNN.  The purpose of this script
# is analogous to sid/extract_ivectors.sh: it creates archives of
# vectors that are used in speaker recognition.  Like ivectors, xvectors can
# be used in PLDA or a similar backend for scoring.

# Begin configuration section.
nj=30
cmd="run.pl"
chunk_size=-1 # The chunk size over which the embedding is extracted.
              # If left unspecified, it uses the max_chunk_size in the nnet
              # directory.
use_gpu=false
stage=0
input_name=

echo "$0 $@"  # Print the command line for logging

if [ -f path.sh ]; then . ./path.sh; fi
. parse_options.sh || exit 1;

if [ $# != 5 ]; then
  echo "Usage: $0 <nnet-dir> <output-node> <data> <embedding> <cvector-dir>"
  echo " e.g.: $0 exp/xvector_nnet data/train exp/embedding exp/xvectors_train"
  echo "main options (for others, see top of script file)"
  echo "  --config <config-file>                           # config containing options"
  echo "  --cmd (utils/run.pl|utils/queue.pl <queue opts>) # how to run jobs."
  echo "  --use-gpu <bool|false>                           # If true, use GPU."
  echo "  --nj <n|30>                                      # Number of jobs"
  echo "  --stage <stage|0>                                # To control partial reruns"
  echo "  --chunk-size <n|-1>                              # If provided, extracts embeddings with specified"
  echo "                                                   # chunk size, and averages to produce final embedding"
  echo "  --input-name <input,embedding>"  
fi

srcdir=$1
output_node=$2
data=$3
embedding=$4
dir=$5

for f in $srcdir/final.raw $srcdir/min_chunk_size $srcdir/max_chunk_size $data/feats.scp $data/vad.scp $embedding/feats.scp; do
  [ ! -f $f ] && echo "No such file $f" && exit 1;
done

min_chunk_size=`cat $srcdir/min_chunk_size 2>/dev/null`
max_chunk_size=`cat $srcdir/max_chunk_size 2>/dev/null`

nnet=$srcdir/final.raw

mkdir -p $dir
echo "$0: extract output for node $output_node"
echo "output-node name=output input=$output_node" > $dir/extract.config
nnet="nnet3-copy --nnet-config=$dir/extract.config $srcdir/final.raw - |"


if [ $chunk_size -le 0 ]; then
  chunk_size=$max_chunk_size
fi

if [ $max_chunk_size -lt $chunk_size ]; then
  echo "$0: specified chunk size of $chunk_size is larger than the maximum chunk size, $max_chunk_size" && exit 1;
fi

mkdir -p $dir/log

echo "$0: extracting cvectors for $data"
utils/split_data.sh $data $nj
sdata=$data/split$nj/JOB

name=`basename $data`

# Set up the features
feat="ark:apply-cmvn-sliding --norm-vars=false --center=true --cmn-window=300 scp:${sdata}/feats.scp ark:- | select-voiced-frames ark:- scp,s,cs:${sdata}/vad.scp ark:- |"

# TODO: WCMVN or not
info="ark:utils/filter_scp.pl ${sdata}/feats.scp $embedding/feats.scp | select-voiced-frames scp:- scp,s,cs:${sdata}/vad.scp ark:- |"
#info="ark:utils/filter_scp.pl ${sdata}/feats.scp $embedding/feats.scp | apply-cmvn-sliding --norm-vars=false --center=true --cmn-window=300 scp:- ark:- | select-voiced-frames ark:- scp,s,cs:${sdata}/vad.scp ark:- |"

if [ $stage -le 0 ]; then
  echo "$0: extracting cvectors from nnet"
  if $use_gpu; then
    for g in $(seq $nj); do
      $cmd --gpu 1 ${dir}/log/extract.$g.log \
        nnet3-cvector-compute-multiple-input --use-gpu=yes --min-chunk-size=$min_chunk_size --chunk-size=$chunk_size --name="$input_name" \
        2 "$nnet" "`echo $feat | sed s/JOB/$g/g`" "`echo $info | sed s/JOB/$g/g`" ark,scp:${dir}/cvector_$name.$g.ark,${dir}/cvector_$name.$g.scp || exit 1 &
    done
    wait
  else
    $cmd JOB=1:$nj ${dir}/log/extract.JOB.log \
      nnet3-cvector-compute-multiple-input --use-gpu=no --min-chunk-size=$min_chunk_size --chunk-size=$chunk_size --name="$input_name" \
      2 "$nnet" "$feat" "$info" ark,scp:${dir}/cvector_$name.JOB.ark,${dir}/cvector_$name.JOB.scp || exit 1;
  fi
fi

if [ $stage -le 1 ]; then
  echo "$0: combining cvectors across jobs"
  for j in $(seq $nj); do cat $dir/cvector_$name.$j.scp; done >$dir/cvector_$name.scp || exit 1;
fi

if [ $stage -le 2 ]; then
  echo "$0: computing mean of cvectors for each speaker"
  $cmd $dir/log/speaker_mean.log \
    ivector-mean ark:$data/spk2utt scp:$dir/cvector_$name.scp \
    ark,scp:$dir/spk_cvector_$name.ark,$dir/spk_cvector_$name.scp ark,t:$dir/num_utts.ark || exit 1;
fi
