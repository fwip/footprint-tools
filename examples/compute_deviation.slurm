#!/bin/bash

# Copyright 2015-2016 Jeff Vierstra

set -e -o pipefail

######## CHANGE VARIABLES BELOW ######## 

bias_model_file=/home/jvierstra/proj/dnase-perspective/cleavage_model/vierstra_et_al.txt

prefix=$1
fasta_file=$2
bam_file=$3
interval_file=$4
output_dir=$5

chrom_sizes_file="${fasta_file%.fa}.chrom.sizes"

echo $prefix
echo $fasta_file
echo $bam_file
echo $interval_file
echo $output_dir

chunksize=10000

# FPR thresholds to call footprints
fps_thresh=(0.2 0.1 0.05 0.01)

######## DO NOT CHANGE BELOW THIS LINE ######## 

mkdir -p ${output_dir}/logs

# load modules
module load bedops/2.4.3
module load python/2.7.11
module load gcc/5.3.0

###

cat <<__SCRIPT__ > ${output_dir}/slurm.learn_dispersion_model
#!/bin/bash
#
#SBATCH --output=${output_dir}/logs/%J.out
#SBATCH --mem=4G
#SBATCH --cpus-per-task=8
#SBATCH --partition=queue1 

set -e -o pipefail

TMPDIR=/tmp/\$SLURM_JOB_ID
mkdir -p \${TMPDIR}

zcat -f ${interval_file} > \${TMPDIR}/intervals.bed

#cat \${TMPDIR}/intervals.bed | random-lines --seed=1 --num=10000 --max=\`wc -l < \${TMPDIR}/intervals.bed\` > \${TMPDIR}/intervals.sampled.bed
cat \${TMPDIR}/intervals.bed > \${TMPDIR}/intervals.sampled.bed

ftd-learn-dispersion-model \
	--bm ${bias_model_file} --half-win-width 5 \
	--processors \${SLURM_CPUS_PER_TASK} \
	${bam_file} ${fasta_file} \${TMPDIR}/intervals.sampled.bed \
> ${output_dir}/dm.json

rm -rf \${TMPDIR}
__SCRIPT__

###

JOB0=$(sbatch --export=ALL \
	--job-name=${prefix}.learn_dm \
	${output_dir}/slurm.learn_dispersion_model)

echo $JOB0

###

cat <<__SCRIPT__ > ${output_dir}/slurm.compute_deviation_chunk
#!/bin/bash
#
#SBATCH --output=${output_dir}/logs/%A.%a.out
#SBATCH --mem=8G
#SBATCH --cpus-per-task=4
#SBATCH --partition=queue1

set -e -o pipefail

INPUT_FILES=(\`cat ${output_dir}/slurm.compute_deviation_chunk.params | head -n \${SLURM_ARRAY_TASK_ID} | tail -n 1\`)

ftd-compute-deviation \
	--bm ${bias_model_file} --half-win-width 5 \
	--smooth-half-win-width 50 --smooth-clip 0.01 \
	--dm ${output_dir}/dm.json --fdr-shuffle-n 50 \
	--processors \${SLURM_CPUS_PER_TASK} \
	${bam_file} ${fasta_file} \${INPUT_FILES[0]} \
| sort --buffer-size=8G -k1,1 -k2,2n > \${INPUT_FILES[0]}.out
__SCRIPT__

###

zcat -f ${interval_file} | split -l ${chunksize} -a 4 -d - ${output_dir}/interval.
ls ${output_dir}/interval.* > ${output_dir}/slurm.compute_deviation_chunk.params

JOB1=$(sbatch --export=ALL \
	--job-name=${prefix}.compute_deviation \
	--array=1-$(wc -l < ${output_dir}/slurm.compute_deviation_chunk.params) \
	--depend=afterok:${JOB0##* } \
	${output_dir}/slurm.compute_deviation_chunk)

echo $JOB1

###

cat <<__SCRIPT__ > ${output_dir}/slurm.compute_deviation_merge_sort
#!/bin/bash
#
#SBATCH --output=${output_dir}/logs/%J.out
#SBATCH --mem=32G
#SBATCH --cpus-per-task=1
#SBATCH --partition=queue0

set -e -o pipefail

INPUT_FILES=(\`cat ${output_dir}/slurm.compute_deviation_chunk.params\`)
OUTPUT_FILES=("\${INPUT_FILES[@]/%/.out}")

sort -k1,1 -k2,2n -S 32G -m \${OUTPUT_FILES[@]} > ${output_dir}/interval.all.bedgraph
__SCRIPT__

###

JOB2=$(sbatch --export=ALL \
	--job-name=${prefix}.merge_sort \
	--depend=afterok:${JOB1##* } \
	${output_dir}/slurm.compute_deviation_merge_sort)

echo $JOB2

###

cat <<__SCRIPT__ > ${output_dir}/slurm.compute_deviation_working_tracks
#!/bin/bash
#
#SBATCH --output=${output_dir}/logs/%J.out
#SBATCH --mem=32G
#SBATCH --cpus-per-task=1
#SBATCH --partition=queue0

set -e -o pipefail

TMPDIR=/tmp/\$SLURM_JOB_ID
mkdir -p \${TMPDIR}

sort-bed --tmpdir \${TMPDIR} --max-mem 32G ${output_dir}/interval.all.bedgraph | starch - > ${output_dir}/interval.all.bedgraph.starch

bgzip -c ${output_dir}/interval.all.bedgraph > ${output_dir}/interval.all.bedgraph.gz
tabix -0 -p bed ${output_dir}/interval.all.bedgraph.gz

rm -rf \${TMPDIR}
__SCRIPT__


cat <<__SCRIPT__ > ${output_dir}/slurm.compute_deviation_footprints
#!/bin/bash
#
#SBATCH --output=${output_dir}/logs/%J.out
#SBATCH --mem=8G
#SBATCH --cpus-per-task=1
#SBATCH --partition=queue1 

set -e -o pipefail

TMPDIR=/tmp/\$SLURM_JOB_ID
mkdir -p \${TMPDIR}

thresholds=(${fps_thresh[@]})
thresh=\${thresholds[\${SLURM_ARRAY_TASK_ID}-1]}

cat ${output_dir}/interval.all.bedgraph \
	| awk -v OFS="\t" -v thresh="\${thresh}" '\$8 <= thresh { print \$1, \$2-3, \$3+3; }' \
	| sort-bed --tmpdir \${TMPDIR} --max-mem 8G - \
	| bedops -m - \
	| awk -v OFS="\t" -v thresh="\${thresh}" '{ \$4="."; \$5=thresh; print; }' \
> ${output_dir}/interval.all.fps.\${thresh}.bed

bgzip -c ${output_dir}/interval.all.fps.\${thresh}.bed > ${output_dir}/interval.all.fps.\${thresh}.bed.gz
tabix -0 -p bed ${output_dir}/interval.all.fps.\${thresh}.bed.gz

rm -rf \${TMPDIR}
__SCRIPT__


cat <<__SCRIPT__ > ${output_dir}/slurm.compute_deviation_browser_tracks
#!/bin/bash
#
#SBATCH --output=${output_dir}/logs/%J.out
#SBATCH --mem=8G
#SBATCH --cpus-per-task=1
#SBATCH --partition=queue0

set -e -o pipefail

TMPDIR=/tmp/\$SLURM_JOB_ID
mkdir -p \${TMPDIR}

cut -f1-3,4 ${output_dir}/interval.all.bedgraph | awk '\$4 > 0 { print; }' > \${TMPDIR}/interval.all.exp.bedgraph
bedGraphToBigWig \${TMPDIR}/interval.all.exp.bedgraph ${chrom_sizes_file} ${output_dir}/interval.all.exp.bw

cut -f1-3,5 ${output_dir}/interval.all.bedgraph | awk '\$4 > 0 { print; }' > \${TMPDIR}/interval.all.obs.bedgraph
bedGraphToBigWig \${TMPDIR}/interval.all.obs.bedgraph ${chrom_sizes_file} ${output_dir}/interval.all.obs.bw

cut -f1-3,6 ${output_dir}/interval.all.bedgraph > \${TMPDIR}/interval.all.lnpval.bedgraph
bedGraphToBigWig \${TMPDIR}/interval.all.lnpval.bedgraph ${chrom_sizes_file} ${output_dir}/interval.all.lnpval.bw

cut -f1-3,7 ${output_dir}/interval.all.bedgraph > \${TMPDIR}/interval.all.winlnpval.bedgraph
bedGraphToBigWig \${TMPDIR}/interval.all.winlnpval.bedgraph ${chrom_sizes_file} ${output_dir}/interval.all.winlnpval.bw

cut -f1-3,8 ${output_dir}/interval.all.bedgraph > \${TMPDIR}/interval.all.fpr.bedgraph
bedGraphToBigWig \${TMPDIR}/interval.all.fpr.bedgraph ${chrom_sizes_file} ${output_dir}/interval.all.fpr.bw

rm -rf \${TMPDIR}
__SCRIPT__


cat <<__SCRIPT__ > ${output_dir}/slurm.compute_deviation_cleanup
#!/bin/bash
#
#SBATCH --output=${output_dir}/logs/%J.out
#SBATCH --cpus-per-task=1
#SBATCH --partition=queue1 

set -e -o pipefail

INPUT_FILES=(\`cat ${output_dir}/slurm.compute_deviation_chunk.params\`)
OUTPUT_FILES=("\${INPUT_FILES[@]/%/.out}")

rm -f \${INPUT_FILES[@]} \${OUTPUT_FILES[@]}

rm -f ${output_dir}/interval.all.bedgraph
__SCRIPT__

cat <<__SCRIPT__ > ${output_dir}/slurm.compute_deviation_beta_prior
#!/bin/bash
#
#SBATCH --output=${output_dir}/logs/%J.out
#SBATCH --cpus-per-task=1
#SBATCH --partition=queue1 

ftd-learn-beta-prior \
	--fdr-cutoff 0.05 --exp-cutoff 10 \
	--processors \${SLURM_CPUS_PER_TASK} \
	${output_dir}/interval.all.bedgraph.gz \
> ${output_dir}/beta_prior.txt
__SCRIPT__

###

JOB3=$(sbatch --export=ALL \
	--job-name=${prefix}.working_tracks \
	--depend=afterok:${JOB2##* } \
	${output_dir}/slurm.compute_deviation_working_tracks)

echo $JOB3

JOB4=$(sbatch --export=ALL \
	--job-name=${prefix}.footprints \
	--array=1-${#fps_thresh[@]} \
	--depend=afterok:${JOB2##* } \
	${output_dir}/slurm.compute_deviation_footprints)

echo $JOB4

JOB5=$(sbatch --export=ALL \
	--job-name=${prefix}.browser_tracks \
	--depend=afterok:${JOB2##* } \
	--partition=queue0 \
	${output_dir}/slurm.compute_deviation_browser_tracks)

echo $JOB5

JOB6=$(sbatch --export=ALL \
	--job-name=${prefix}.cleanup \
	--depend=afterok:${JOB3##* }:${JOB4##* }:${JOB5##* } \
	${output_dir}/slurm.compute_deviation_cleanup)

echo $JOB6

JOB7=$(sbatch --export=ALL \
	--job-name=${prefix}.beta_prior \
	--depend=afterok:${JOB3##* } \
	${output_dir}/slurm.compute_deviation_beta_prior)

echo $JOB7
