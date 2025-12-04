#!/bin/bash
#$ -cwd
#$ -q fsmall
#$ -pe OpenMP 4
#$ -l mem_req=128G
#$ -l h_vmem=32g
#$ -N T2T_T2Tmap
#$ -o ~/T2T_pipeline/work/logs/qsub_$JOB_ID.out
#$ -e ~/T2T_pipeline/work/logs/qsub_$JOB_ID.err
#$ -j y

set -euo pipefail

########################################
# 0. 設定ファイルの読み込み
########################################
# SGE 環境なら SGE_O_WORKDIR（qsub したディレクトリ）を優先的に使う
# それがなければカレントディレクトリを REPO_ROOT とみなす
REPO_ROOT="${SGE_O_WORKDIR:-$(pwd)}"
source "${REPO_ROOT}/config/config.sh"

########################################
# 1. サンプルIDの決定
########################################
SAMPLES_TSV="${REPO_ROOT}/samples/samples.tsv"

if [[ $# -ge 1 ]]; then
  SAMPLE="$1"
else
  if [[ -z "${SGE_TASK_ID:-}" ]]; then
    echo "ERROR: SAMPLE not specified and SGE_TASK_ID is empty." >&2
    exit 1
  fi
  LINE_NUM=$(( SGE_TASK_ID + 1 ))   # 1行目はヘッダーなので +1
  SAMPLE=$(sed -n "${LINE_NUM}p" "${SAMPLES_TSV}" | cut -f1)
  if [[ -z "${SAMPLE}" ]]; then
    echo "ERROR: No sample found for SGE_TASK_ID=${SGE_TASK_ID} (line ${LINE_NUM})." >&2
    exit 1
  fi
fi

echo "SAMPLE = ${SAMPLE}"

########################################
# 2. ログ設定
########################################
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SAMPLE_LOG_DIR="${LOG_DIR}/${SAMPLE}"
mkdir -p "${SAMPLE_LOG_DIR}"

LOG="${SAMPLE_LOG_DIR}/${SAMPLE}_T2T_pipeline_${TIMESTAMP}.log"

echo "Log file: ${LOG}"
exec > >(tee -a "${LOG}") 2>&1

echo "=================================================="
echo "  T2T pipeline start for ${SAMPLE}"
echo "  Date: $(date)"
echo "  Work dir: ${WORK_DIR}"
echo "  Reference: ${T2T_REF}"
echo "=================================================="

export OMP_NUM_THREADS=${NSLOTS:-4}

########################################
# 3. STEP 1: prefetch
########################################
echo "[STEP 1] Downloading SRA with prefetch ..."
cd "${RAW_SRA_DIR}"

singularity exec --bind "${WORK_DIR}:${WORK_DIR}" "${SRA_IMG}" \
  prefetch \
    --max-size 100G \
    --output-directory "${RAW_SRA_DIR}" \
    "${SAMPLE}"

echo "  -> downloaded files in ${RAW_SRA_DIR}:"
ls -lh "${RAW_SRA_DIR}"

########################################
# 4. STEP 2: fasterq-dump
########################################
echo "[STEP 2] Converting SRA to FASTQ (fasterq-dump) ..."
cd "${FASTQ_DIR}"

singularity exec --bind "${WORK_DIR}:${WORK_DIR}" "${SRA_IMG}" \
  fasterq-dump \
    --split-files \
    --threads "${OMP_NUM_THREADS}" \
    -O "${FASTQ_DIR}" \
    "${RAW_SRA_DIR}/${SAMPLE}"

echo "  -> FASTQ files:"
ls -lh "${FASTQ_DIR}/${SAMPLE}_*.fastq"

########################################
# 5. STEP 3: gzip
########################################
echo "[STEP 3] Gzipping FASTQ ..."
gzip "${FASTQ_DIR}/${SAMPLE}_1.fastq"
gzip "${FASTQ_DIR}/${SAMPLE}_2.fastq"

echo "  -> gzipped FASTQ files:"
ls -lh "${FASTQ_DIR}/${SAMPLE}_*.fastq.gz"

########################################
# 6. STEP 4: trim_galore
########################################
echo "[STEP 4] Running trim_galore for ${SAMPLE} ..."
cd "${TRIM_DIR}"

singularity exec --bind "${WORK_DIR}:${WORK_DIR}" "${TRIM_GALORE_IMG}" \
  trim_galore \
    --paired \
    "${FASTQ_DIR}/${SAMPLE}_1.fastq.gz" \
    "${FASTQ_DIR}/${SAMPLE}_2.fastq.gz" \
    -o "${TRIM_DIR}"

echo "  -> trimmed FASTQ files:"
ls -lh "${TRIM_DIR}"

TRIM1="${TRIM_DIR}/${SAMPLE}_1_val_1.fq.gz"
TRIM2="${TRIM_DIR}/${SAMPLE}_2_val_2.fq.gz"

########################################
# 7. STEP 5: BWA MEM → raw BAM
########################################
echo "[STEP 5] BWA MEM mapping to T2T-hs1 ..."
mkdir -p "${BAM_DIR}"

singularity exec --bind "${WORK_DIR}:${WORK_DIR},${REF_DIR}:${REF_DIR}" "${BWA_IMG}" \
  bwa mem -t "${OMP_NUM_THREADS}" -Y -K 100000000 \
    "${T2T_REF}" \
    "${TRIM1}" "${TRIM2}" \
  | singularity exec --bind "${WORK_DIR}:${WORK_DIR}" "${SAMTOOLS_IMG}" \
      samtools view -b -@ "${OMP_NUM_THREADS}" -o "${BAM_DIR}/${SAMPLE}_raw_T2T.bam" -

echo "  -> raw BAM:"
ls -lh "${BAM_DIR}/${SAMPLE}_raw_T2T.bam"

########################################
# 8. STEP 6: sort + index
########################################
echo "[STEP 6] Sorting raw BAM ..."
singularity exec --bind "${WORK_DIR}:${WORK_DIR}" "${SAMTOOLS_IMG}" \
  samtools sort -@ "${OMP_NUM_THREADS}" -m 2G \
    -o "${BAM_DIR}/${SAMPLE}_sorted_T2T.bam" \
    "${BAM_DIR}/${SAMPLE}_raw_T2T.bam"

echo "  -> sorted BAM:"
ls -lh "${BAM_DIR}/${SAMPLE}_sorted_T2T.bam"

echo "[STEP 6] Indexing sorted BAM ..."
singularity exec --bind "${WORK_DIR}:${WORK_DIR}" "${SAMTOOLS_IMG}" \
  samtools index "${BAM_DIR}/${SAMPLE}_sorted_T2T.bam"

########################################
# 9. STEP 7: MarkDuplicates → final BAM
########################################
echo "[STEP 7] MarkDuplicates (REMOVE_DUPLICATES=true) ..."
singularity exec --bind "${WORK_DIR}:${WORK_DIR}" "${PICARD_IMG}" \
  picard -Xmx16g MarkDuplicates \
    ASSUME_SORTED=true \
    REMOVE_DUPLICATES=true \
    I="${BAM_DIR}/${SAMPLE}_sorted_T2T.bam" \
    O="${BAM_DIR}/${SAMPLE}_dedup_T2T.bam" \
    M="${METRICS_DIR}/metrics_${SAMPLE}_dedup_T2T.txt"

echo "  -> dedup BAM:"
ls -lh "${BAM_DIR}/${SAMPLE}_dedup_T2T.bam"
echo "  -> metrics:"
ls -lh "${METRICS_DIR}/metrics_${SAMPLE}_dedup_T2T.txt"

echo "[STEP 7] Sorting deduplicated BAM to final ..."
singularity exec --bind "${WORK_DIR}:${WORK_DIR}" "${SAMTOOLS_IMG}" \
  samtools sort -@ "${OMP_NUM_THREADS}" -m 2G \
    -o "${FINAL_BAM_DIR}/${SAMPLE}_final_T2T.bam" \
    "${BAM_DIR}/${SAMPLE}_dedup_T2T.bam"

echo "[STEP 7] Indexing final BAM ..."
singularity exec --bind "${WORK_DIR}:${WORK_DIR}" "${SAMTOOLS_IMG}" \
  samtools index "${FINAL_BAM_DIR}/${SAMPLE}_final_T2T.bam"

echo "  -> final BAM:"
ls -lh "${FINAL_BAM_DIR}/${SAMPLE}_final_T2T.bam"*

########################################
# 10. STEP 8: QC flagstat
########################################
echo "[STEP 8] Running flagstat (pre/post dedup) ..."

singularity exec --bind "${WORK_DIR}:${WORK_DIR}" "${SAMTOOLS_IMG}" \
  samtools flagstat "${BAM_DIR}/${SAMPLE}_sorted_T2T.bam" \
  > "${QC_DIR}/${SAMPLE}.sorted.flagstat.txt"

singularity exec --bind "${WORK_DIR}:${WORK_DIR}" "${SAMTOOLS_IMG}" \
  samtools flagstat "${FINAL_BAM_DIR}/${SAMPLE}_final_T2T.bam" \
  > "${QC_DIR}/${SAMPLE}.final.flagstat.txt"

echo "  -> flagstat outputs:"
ls -lh "${QC_DIR}/${SAMPLE}."*.flagstat.txt"

########################################
# 11. STEP 9: 特定領域の samtools view
########################################
REGION="chr15:26977657-26978006"

echo "[STEP 9] Inspecting region ${REGION} (before dedup) ..."
singularity exec --bind "${WORK_DIR}:${WORK_DIR}" "${SAMTOOLS_IMG}" \
  samtools view -h "${BAM_DIR}/${SAMPLE}_sorted_T2T.bam" "${REGION}" | head -n 40 \
  > "${QC_DIR}/${SAMPLE}.sorted.${REGION//:/_}.head.sam"

echo "[STEP 9] Inspecting region ${REGION} (after dedup) ..."
singularity exec --bind "${WORK_DIR}:${WORK_DIR}" "${SAMTOOLS_IMG}" \
  samtools view -h "${FINAL_BAM_DIR}/${SAMPLE}_final_T2T.bam" "${REGION}" | head -n 40 \
  > "${QC_DIR}/${SAMPLE}.final.${REGION//:/_}.head.sam"

echo "  -> region SAM head files:"
ls -lh "${QC_DIR}/${SAMPLE}."*".${REGION//:/_}.head.sam"

########################################
# 12. 終了
########################################
echo "=================================================="
echo "  T2T pipeline finished for ${SAMPLE}"
echo "  End time: $(date)"
echo "  Log: ${LOG}"
echo "=================================================="
