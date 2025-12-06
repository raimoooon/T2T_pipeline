# T2T WGS Mapping Pipeline

公共データベース（SRA）のヒト WGS ペアエンドリードを  
UCSC `hs1`（T2T-CHM13v2.0）リファレンスにマッピングし、  
重複除去済み BAM と QC を自動で生成するパイプラインです。

本来の目的は「統合失調症患者・健常者ニューロンの WGS を T2T にマッピングし、  
転移因子（Transposable Elements; TE）解析につなげること」ですが、  
任意のヒト WGS（SRA アクセッション）に対して利用可能な構成になっています。
TE 解析に先立って行う前処理（トリミング・T2T へのマッピング）および
品質管理（重複除去・flagstat など）を複数サンプルに対して一括実行するための
パイプラインを提供します。

## 依存環境

- ジョブスケジューラ: Sun Grid Engine (SGE, `qsub`)
  -Sun Grid Engine (SGE) 環境を想定
  -キュー名や並列環境名は各自のクラスター設定に合わせて変更してください。
- コンテナ環境: Singularity（または Apptainer）
- Singularity イメージ（パスは `config/config.sh` で指定）
  - `sratools.sif`  (prefetch, fasterq-dump)
  - `bwa.sif`
  - `samtools.sif`
  - `picard.sif`
  - `trim_galore.sif`
- T2T リファレンスゲノム
  - UCSC から `hs1.fa.gz` を取得し展開後、`T2T-hs1.fa` にリネーム

## ディレクトリ構成（コード部分）

```text
T2T_pipeline/
  README.md
  .gitignore
  config/
    config.example.sh   # テンプレート
    # config.sh         # 自分の環境用（Git 管理外）
  samples/
    samples.tsv         # サンプル一覧 (sample_id, group)
    # control.txt / patient.txt などは任意で追加
  scripts/
    run_sample_sge.sh   # 1サンプル分のパイプライン本体
    submit_array_sge.sh # SGE 配列ジョブ投入用ラッパー
  work/
    raw_sra/
    fastq/
    trimmed/
    bam/
      final/
    qc/
      metrics/
    logs/


