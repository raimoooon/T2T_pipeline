#!/bin/bash
#$ -cwd
#$ -q fsmall
#$ -pe OpenMP 4
#$ -l mem_req=128G
#$ -l h_vmem=32g
#$ -N T2T_BLQC
#$ -o /home/raimoon/soturon/WGS_data/T2T_pipeline/work/logs/qsub_$JOB_ID.out
#$ -e /home/raimoon/soturon/WGS_data/T2T_pipeline/work/logs/qsub_$JOB_ID.err
#$ -j y

set -euo pipefail

########################################
# 0. 設定ファイルの読み込み
########################################
# qsub を投げたディレクトリを REPO_ROOT とみなす
REPO_ROOT="${SGE_O_WORKDIR:-/home/raimoon/soturon/WGS_data/T2T_pipeline}"
source "${REPO_ROOT}/config/config.sh"

echo "==== DEBUG PATHS ===="
echo "REPO_ROOT     = ${REPO_ROOT}"
echo "WORK_DIR      = ${WORK_DIR}"
echo "RAW_SRA_DIR   = ${RAW_SRA_DIR}"
echo "FASTQ_DIR     = ${FASTQ_DIR}"
echo "TRIM_DIR      = ${TRIM_DIR}"
echo "BAM_DIR       = ${BAM_DIR}"
echo "FINAL_BAM_DIR = ${FINAL_BAM_DIR}"
echo "QC_DIR        = ${QC_DIR}"
echo "T2T_REF       = ${T2T_REF}"
echo "BL_BED        = ${BL_BED:-NA}"
echo "======================"

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

SRA_SUBDIR="${RAW_SRA_DIR}/${SAMPLE}"
SRA_FILE="${SRA_SUBDIR}/${SAMPLE}.sra"

if [[ -f "${SRA_FILE}" ]]; then
  echo "  -> SRA already exists, skip prefetch"
else
  echo "  -> SRA not found, run prefetch"
  rm -rf "${SRA_SUBDIR}"
  mkdir -p "${SRA_SUBDIR}"

  singularity exec --bind "${WORK_DIR}:${WORK_DIR}" "${SRA_IMG}" \
    prefetch \
      --max-size 100G \
      --output-directory "${RAW_SRA_DIR}" \
      "${SAMPLE}"
fi

echo "  -> downloaded files in ${SRA_SUBDIR}:"
ls -lh "${SRA_SUBDIR}"

if [[ ! -f "${SRA_FILE}" ]]; then
  echo "ERROR: SRA file not found: ${SRA_FILE}" >&2
  exit 1
fi

########################################
# 4. STEP 2: fasterq-dump
########################################
echo "[STEP 2] Converting SRA to FASTQ (fasterq-dump) ..."
cd "${FASTQ_DIR}"

FASTQ1="${FASTQ_DIR}/${SAMPLE}_1.fastq"
FASTQ2="${FASTQ_DIR}/${SAMPLE}_2.fastq"

if [[ -f "${FASTQ1}" && -f "${FASTQ2}" ]]; then
  echo "  -> FASTQ already exists, skip fasterq-dump"
else
  echo "  -> run fasterq-dump"
  singularity exec --bind "${WORK_DIR}:${WORK_DIR}" "${SRA_IMG}" \
    fasterq-dump \
      --split-files \
      --threads "${OMP_NUM_THREADS}" \
      -O "${FASTQ_DIR}" \
      "${SRA_FILE}"
fi

if [[ ! -f "${FASTQ1}" || ! -f "${FASTQ2}" ]]; then
  echo "ERROR: FASTQ not found in ${FASTQ_DIR} for ${SAMPLE}" >&2
  ls -lh "${FASTQ_DIR}"
  exit 1
fi

echo "  -> FASTQ files:"
ls -lh "${FASTQ1}" "${FASTQ2}"

########################################
# 5. STEP 3: gzip
########################################
echo "[STEP 3] Gzipping FASTQ ..."

GZ1="${FASTQ1}.gz"
GZ2="${FASTQ2}.gz"

if [[ -f "${GZ1}" && -f "${GZ2}" ]]; then
  echo "  -> gzipped FASTQ already exists, skip gzip"
else
  echo "  -> run gzip"
  gzip -v "${FASTQ1}"
  gzip -v "${FASTQ2}"
fi

if [[ ! -f "${GZ1}" || ! -f "${GZ2}" ]]; then
  echo "ERROR: gzipped FASTQ not found for ${SAMPLE}" >&2
  ls -lh "${FASTQ_DIR}"
  exit 1
fi

echo "  -> gzipped FASTQ files:"
ls -lh "${GZ1}" "${GZ2}"

########################################
# 6. STEP 4: trim_galore
########################################
echo "[STEP 4] Running trim_galore for ${SAMPLE} ..."
cd "${TRIM_DIR}"

TRIM1="${TRIM_DIR}/${SAMPLE}_1_val_1.fq.gz"
TRIM2="${TRIM_DIR}/${SAMPLE}_2_val_2.fq.gz"

if [[ -f "${TRIM1}" && -f "${TRIM2}" ]]; then
  echo "  -> trimmed FASTQ already exists, skip trim_galore"
else
  echo "  -> run trim_galore"
  singularity exec --bind "${WORK_DIR}:${WORK_DIR}" "${TRIM_GALORE_IMG}" \
    trim_galore \
      --paired \
      "${GZ1}" \
      "${GZ2}" \
      -o "${TRIM_DIR}"
fi

if [[ ! -f "${TRIM1}" || ! -f "${TRIM2}" ]]; then
  echo "ERROR: trimmed FASTQ not found for ${SAMPLE}" >&2
  ls -lh "${TRIM_DIR}"
  exit 1
fi

echo "  -> trimmed FASTQ files:"
ls -lh "${TRIM1}" "${TRIM2}"

########################################
# 7. STEP 5: BWA MEM → raw BAM
########################################
echo "[STEP 5] BWA MEM mapping to T2T-hs1 ..."
mkdir -p "${BAM_DIR}"

RAW_BAM="${BAM_DIR}/${SAMPLE}_raw_T2T.bam"

if [[ -f "${RAW_BAM}" ]]; then
  echo "  -> raw BAM already exists, skip BWA MEM"
else
  echo "  -> run BWA MEM + samtools view"
  singularity exec --bind "${WORK_DIR}:${WORK_DIR},${REF_DIR}:${REF_DIR}" "${BWA_IMG}" \
    bwa mem -t "${OMP_NUM_THREADS}" -Y -K 100000000 \
      "${T2T_REF}" \
      "${TRIM1}" "${TRIM2}" \
    | singularity exec --bind "${WORK_DIR}:${WORK_DIR}" "${SAMTOOLS_IMG}" \
        samtools view -b -@ "${OMP_NUM_THREADS}" -o "${RAW_BAM}" -
fi

echo "  -> raw BAM:"
ls -lh "${RAW_BAM}"

########################################
# 8. STEP 6: sort + index
########################################
echo "[STEP 6] Sorting raw BAM ..."

SORT_BAM="${BAM_DIR}/${SAMPLE}_sorted_T2T.bam"
SORT_BAI="${SORT_BAM}.bai"

if [[ -f "${SORT_BAM}" ]]; then
  echo "  -> sorted BAM already exists, skip sort"
else
  echo "  -> run samtools sort"
  singularity exec --bind "${WORK_DIR}:${WORK_DIR}" "${SAMTOOLS_IMG}" \
    samtools sort -@ "${OMP_NUM_THREADS}" -m 2G \
      -o "${SORT_BAM}" \
      "${RAW_BAM}"
fi

echo "  -> sorted BAM:"
ls -lh "${SORT_BAM}"

echo "[STEP 6] Indexing sorted BAM ..."
if [[ ! -f "${SORT_BAI}" ]]; then
  singularity exec --bind "${WORK_DIR}:${WORK_DIR}" "${SAMTOOLS_IMG}" \
    samtools index "${SORT_BAM}"
fi

########################################
# 9. STEP 7: MarkDuplicates → final BAM
########################################
echo "[STEP 7] MarkDuplicates (REMOVE_DUPLICATES=true) ..."

DEDUP_BAM="${BAM_DIR}/${SAMPLE}_dedup_T2T.bam"
METRICS_FILE="${METRICS_DIR}/metrics_${SAMPLE}_dedup_T2T.txt"
FINAL_BAM="${FINAL_BAM_DIR}/${SAMPLE}_final_T2T.bam"
FINAL_BAI="${FINAL_BAM}.bai"

if [[ -f "${DEDUP_BAM}" && -f "${METRICS_FILE}" ]]; then
  echo "  -> dedup BAM & metrics already exist, skip MarkDuplicates"
else
  echo "  -> run picard MarkDuplicates"
  singularity exec --bind "${WORK_DIR}:${WORK_DIR}" "${PICARD_IMG}" \
    picard -Xmx16g MarkDuplicates \
      ASSUME_SORTED=true \
      REMOVE_DUPLICATES=true \
      I="${SORT_BAM}" \
      O="${DEDUP_BAM}" \
      M="${METRICS_FILE}"
fi

echo "  -> dedup BAM:"
ls -lh "${DEDUP_BAM}"
echo "  -> metrics:"
ls -lh "${METRICS_FILE}"

echo "[STEP 7] Sorting deduplicated BAM to final ..."
mkdir -p "${FINAL_BAM_DIR}"

if [[ -f "${FINAL_BAM}" ]]; then
  echo "  -> final BAM already exists, skip sort"
else
  echo "  -> run final samtools sort"
  singularity exec --bind "${WORK_DIR}:${WORK_DIR}" "${SAMTOOLS_IMG}" \
    samtools sort -@ "${OMP_NUM_THREADS}" -m 2G \
      -o "${FINAL_BAM}" \
      "${DEDUP_BAM}"
fi

echo "[STEP 7] Indexing final BAM ..."
if [[ ! -f "${FINAL_BAI}" ]]; then
  singularity exec --bind "${WORK_DIR}:${WORK_DIR}" "${SAMTOOLS_IMG}" \
    samtools index "${FINAL_BAM}"
fi

echo "  -> final BAM:"
ls -lh "${FINAL_BAM}"*

########################################
# 10. STEP 8: QC flagstat（全体 QC）
########################################
echo "[STEP 8] Running flagstat (pre/post dedup) ..."

SORT_FLAGSTAT="${QC_DIR}/${SAMPLE}.sorted.flagstat.txt"
FINAL_FLAGSTAT="${QC_DIR}/${SAMPLE}.final.flagstat.txt"

if [[ ! -f "${SORT_FLAGSTAT}" ]]; then
  singularity exec --bind "${WORK_DIR}:${WORK_DIR}" "${SAMTOOLS_IMG}" \
    samtools flagstat "${SORT_BAM}" \
    > "${SORT_FLAGSTAT}"
fi

if [[ ! -f "${FINAL_FLAGSTAT}" ]]; then
  singularity exec --bind "${WORK_DIR}:${WORK_DIR}" "${SAMTOOLS_IMG}" \
    samtools flagstat "${FINAL_BAM}" \
    > "${FINAL_FLAGSTAT}"
fi

echo "  -> flagstat outputs:"
ls -lh "${SORT_FLAGSTAT}" "${FINAL_FLAGSTAT}"

########################################
# 11. STEP 9: ブラックリスト全領域の QC（T2Tアーティファクト対策の肝）
########################################
if [[ -f "${BL_BED}" ]]; then
  echo "[STEP 9] QC on all blacklist regions in ${BL_BED}"

  # 全マップリード数（sorted / final）
  TOTAL_MAPPED_SORT=$(
    singularity exec --bind "${WORK_DIR}:${WORK_DIR}" "${SAMTOOLS_IMG}" \
      samtools view -c -F 4 "${SORT_BAM}"
  )
  TOTAL_MAPPED_FINAL=$(
    singularity exec --bind "${WORK_DIR}:${WORK_DIR}" "${SAMTOOLS_IMG}" \
      samtools view -c -F 4 "${FINAL_BAM}"
  )

  COV_TSV="${QC_DIR}/${SAMPLE}.blacklist_coverage.tsv"
  : > "${COV_TSV}"
  echo -e "region_name\tchr\tstart\tend\tlen\t"\
"mean_depth_sorted\tmean_depth_final\t"\
"sum_depth_sorted\tsum_depth_final\t"\
"read_count_sorted\tread_count_final\t"\
"frac_reads_sorted\tfrac_reads_final" >> "${COV_TSV}"

  while read -r CHR START END NAME; do
    REGION="${CHR}:${START}-${END}"
    [[ -z "${NAME}" ]] && NAME="${CHR}_${START}_${END}"
    LEN=$(( END - START ))

    echo "  - processing ${NAME} (${REGION})"

    # depth から合計・平均カバレッジを計算（sorted）
    read SUM_SORT MEAN_SORT <<< "$(
      singularity exec --bind "${WORK_DIR}:${WORK_DIR}" "${SAMTOOLS_IMG}" \
        samtools depth -r "${REGION}" "${SORT_BAM}" \
      | awk '{sum+=$3; n++} END { if (n>0) printf "%f %f", sum, sum/n; else print "0 0"}'
    )"

    # depth から合計・平均カバレッジを計算（final）
    read SUM_FINAL MEAN_FINAL <<< "$(
      singularity exec --bind "${WORK_DIR}:${WORK_DIR}" "${SAMTOOLS_IMG}" \
        samtools depth -r "${REGION}" "${FINAL_BAM}" \
      | awk '{sum+=$3; n++} END { if (n>0) printf "%f %f", sum, sum/n; else print "0 0"}'
    )"

    # リード本数（sorted / final）
    READS_SORT=$(
      singularity exec --bind "${WORK_DIR}:${WORK_DIR}" "${SAMTOOLS_IMG}" \
        samtools view -c "${SORT_BAM}" "${REGION}"
    )
    READS_FINAL=$(
      singularity exec --bind "${WORK_DIR}:${WORK_DIR}" "${SAMTOOLS_IMG}" \
        samtools view -c "${FINAL_BAM}" "${REGION}"
    )

    # 全マップリード数に対する割合
    FRAC_SORT=$(awk -v r="${READS_SORT}" -v tot="${TOTAL_MAPPED_SORT}" \
      'BEGIN{ if(tot>0) printf "%.6f", r/tot; else print 0 }')
    FRAC_FINAL=$(awk -v r="${READS_FINAL}" -v tot="${TOTAL_MAPPED_FINAL}" \
      'BEGIN{ if(tot>0) printf "%.6f", r/tot; else print 0 }')

    printf "%s\t%s\t%d\t%d\t%d\t%.2f\t%.2f\t%.0f\t%.0f\t%d\t%d\t%.6f\t%.6f\n" \
      "${NAME}" "${CHR}" "${START}" "${END}" "${LEN}" \
      "${MEAN_SORT}" "${MEAN_FINAL}" \
      "${SUM_SORT}" "${SUM_FINAL}" \
      "${READS_SORT}" "${READS_FINAL}" \
      "${FRAC_SORT}" "${FRAC_FINAL}" \
      >> "${COV_TSV}"

    # 代表 SAM（before / after）
    SORT_HEAD="${QC_DIR}/${SAMPLE}.sorted.${NAME}.head.sam"
    FINAL_HEAD="${QC_DIR}/${SAMPLE}.final.${NAME}.head.sam"

    singularity exec --bind "${WORK_DIR}:${WORK_DIR}" "${SAMTOOLS_IMG}" \
      samtools view -h "${SORT_BAM}" "${REGION}" | head -n 40 > "${SORT_HEAD}"

    singularity exec --bind "${WORK_DIR}:${WORK_DIR}" "${SAMTOOLS_IMG}" \
      samtools view -h "${FINAL_BAM}" "${REGION}" | head -n 40 > "${FINAL_HEAD}"

  done < "${BL_BED}"

  echo "  -> blacklist coverage summary: ${COV_TSV}"
else
  echo "[STEP 9] No blacklist BED found (${BL_BED}), skip blacklist QC"
fi

########################################
# 12. 終了
########################################
echo "=================================================="
echo "  T2T pipeline finished for ${SAMPLE}"
echo "  End time: $(date)"
echo "  Log: ${LOG}"
echo "=================================================="
