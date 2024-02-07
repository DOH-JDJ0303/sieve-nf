//
// Check input samplesheet and get read channels
//

include { BWA_MEM          } from '../../modules/local/bwa_mem'
include { SAMTOOLSTATS2TBL } from '../../modules/local/samtoolstats2tbl'
include { MAPPED_FASTQ     } from '../../modules/local/get_mapped_fastq'
include { IVAR_CONSENSUS   } from '../../modules/local/ivar_consensus'
include { NEXTCLADE_RUN    } from '../../modules/local/nexclade/run/main'


workflow ASSEMBLE {
    take:
    ref_list // channel: [sample_meta, ref_id, ref_path, reads]

    main:

    ch_versions = Channel.empty()
    
    /* 
    =============================================================================================================================
        ALIGN FULL READ SET TO REFERENCES
    =============================================================================================================================
    */ 

    // MODULE: Run BWA MEM
    BWA_MEM (
        ref_list    
    )
    ch_versions = ch_versions.mix(BWA_MEM.out.versions.first())

    // MODULE: Summarize Samtool stats
    SAMTOOLSTATS2TBL (
        BWA_MEM.out.stats
    )

    // MODULE: Convert mapped reads to FASTQ
    MAPPED_FASTQ (
        BWA_MEM.out.read_list.map{meta, ref, read_list -> [ meta, ref, read_list ] }.join(ref_list, by: [0,1])
    )

    /* 
    =============================================================================================================================
        CREATE CONSENSUS ASSEMBLY
    =============================================================================================================================
    */ 

    // MODULE: Run Ivar
    IVAR_CONSENSUS (
        BWA_MEM.out.bam
    )
    ch_versions = ch_versions.mix(IVAR_CONSENSUS.out.versions.first())

    /* 
    =============================================================================================================================
        ASSEMBLY QC METRICS
    =============================================================================================================================
    */
    // MODULE: Run Nextclade
    NEXTCLADE_RUN (
        IVAR_CONSENSUS.out.consensus.join(ref_list.map{ meta, ref_id, ref_path, reads -> [ meta, ref_id, ref_path ] }, by: [0,1]),
        file("${baseDir}/assets/nextclade-template.json", checkIfExists: true)
    )

    emit:
    samtoolstats2tbl = SAMTOOLSTATS2TBL.out.tbl // channel: [ val(meta), val(ref), path(stats)) ]
    nextflow         = NEXTCLADE_RUN.out.tsv    // channel: [ val(meta), val(ref), path(stats)) ]
}
