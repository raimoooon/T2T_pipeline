#!/bin/bash

########################################
# パス・環境設定（自分の環境に合わせて編集）
########################################

# リポジトリルート（このファイルの1つ上の階層）
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# 作業ディレクトリ
WORK_DIR="${REPO_ROOT}/work"

# 解析対象リファレンスFASTA
# /home/USERNAME/Reference/T2T-hs1.fa を想定
REF_DIR="/home/USERNAME/Reference"
TOOL_DIR="/home/USERNAME/Tools"

# Singularity イメージの置き場所
TOOL_DIR="/home/raimoon/soturon/Tools"

SRA_IMG="${TOOL_DIR}/sratools.sif"
BWA_IMG="${TOOL_DIR}/bwa.sif"
SAMTOOLS_IMG="${TOOL_DIR}/samtools.sif"
PICARD_IMG="${TOOL_DIR}/picard.sif"
TRIM_GALORE_IMG="${TOOL_DIR}/trim_galore.sif"

# SGE 関連
SGE_QUEUE="fsmall"
SGE_PE="OpenMP"
SGE_THREADS=4
SGE_MEM_REQ="128G"
SGE_H_VMEM="32G"

########################################
# 作業用サブディレクトリ
########################################

RAW_SRA_DIR="${WORK_DIR}/raw_sra"
FASTQ_DIR="${WORK_DIR}/fastq"
TRIM_DIR="${WORK_DIR}/trimmed"
BAM_DIR="${WORK_DIR}/bam"
FINAL_BAM_DIR="${BAM_DIR}/final"
QC_DIR="${WORK_DIR}/qc"
LOG_DIR="${WORK_DIR}/logs"
METRICS_DIR="${QC_DIR}/metrics"

mkdir -p \
  "${RAW_SRA_DIR}" "${FASTQ_DIR}" "${TRIM_DIR}" \
  "${BAM_DIR}" "${FINAL_BAM_DIR}" \
  "${QC_DIR}" "${LOG_DIR}" "${METRICS_DIR}"
