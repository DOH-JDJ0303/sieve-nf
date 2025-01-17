/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    PRINT PARAMS SUMMARY
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { paramsSummaryLog; paramsSummaryMap } from 'plugin/nf-validation'

def logo = NfcoreTemplate.logo(workflow, params.monochrome_logs)
def citation = '\n' + WorkflowMain.citation(workflow) + '\n'
def summary_params = paramsSummaryMap(workflow)

// Print parameter summary log to screen
log.info logo + paramsSummaryLog(workflow) + citation

WorkflowVaper.initialise(params, log)

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    CONFIG FILES
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

ch_multiqc_config          = Channel.fromPath("$projectDir/assets/multiqc_config.yml", checkIfExists: true)
ch_multiqc_custom_config   = params.multiqc_config ? Channel.fromPath( params.multiqc_config, checkIfExists: true ) : Channel.empty()
ch_multiqc_logo            = params.multiqc_logo   ? Channel.fromPath( params.multiqc_logo, checkIfExists: true ) : Channel.empty()
ch_multiqc_custom_methods_description = params.multiqc_methods_description ? file(params.multiqc_methods_description, checkIfExists: true) : file("$projectDir/assets/methods_description_template.yml", checkIfExists: true)

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT LOCAL MODULES/SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

//
// MODULE: Local modules
//
include { FASTP2TBL            } from '../modules/local/fastp2tbl'
include { SUMMARYLINE          } from '../modules/local/create-summaryline'
include { COMBINE_SUMMARYLINES } from '../modules/local/combine-summary'

//
// SUBWORKFLOW: Consisting of a mix of local and nf-core/modules
//
include { INPUT_CHECK } from '../subworkflows/local/input_check'
include { CLASSIFY    } from '../subworkflows/local/classify'
include { ASSEMBLE    } from '../subworkflows/local/assemble'
include { VALIDATE    } from '../subworkflows/local/validate'


/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT NF-CORE MODULES/SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

//
// MODULE: Installed directly from nf-core/modules
//
include { FASTQC                      } from '../modules/nf-core/fastqc/main'
include { SEQTK_SAMPLE                } from '../modules/nf-core/seqtk/sample/main'
include { FASTP                       } from '../modules/nf-core/fastp/main'
include { MULTIQC                     } from '../modules/nf-core/multiqc/main'
include { CUSTOM_DUMPSOFTWAREVERSIONS } from '../modules/nf-core/custom/dumpsoftwareversions/main'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN MAIN WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

// Info required for completion email and summary
def multiqc_report = []

workflow VAPER {

    ch_versions = Channel.empty()

    /* 
    =============================================================================================================================
        PREPARE INPUT
    =============================================================================================================================
    */
    // SUBWORKFLOW: Read in samplesheet, validate and stage input files
    INPUT_CHECK (
        file(params.input),
        file(params.refs)
    )
    ch_versions = ch_versions.mix(INPUT_CHECK.out.versions)

    INPUT_CHECK.out.reads.map{ meta, reads, reference, truth, inter_group, intra_group -> [ meta, reads ] }.set{ ch_reads }
    INPUT_CHECK.out.refs.set{ ch_refs }
    INPUT_CHECK.out.refsheet.set{ ch_refsheet }


    /* 
    =============================================================================================================================
        QUALITY CONTROL: READS
    =============================================================================================================================
    */

    //
    // MODULE: Downsample reads with Seqtk Subseq
    //
    if(params.max_reads){
        // determine samples with too many reads
        ch_reads
            .map{ meta, reads -> [ meta: meta, reads: reads, n: reads[0].countFastq()*2 ] }
            .branch{ it -> 
                ok: it.n <= params.max_reads
                high: it.n > params.max_reads  }
            .set{ ch_reads }
        // create foward and reverse read channels
        ch_reads
            .high
            .map{it -> [ it.meta, it.reads[0], params.max_reads ] }
            .set{ch_fwd}
        ch_reads
            .high
            .map{ it -> [ it.meta, it.reads[1], params.max_reads ] }
            .set{ch_rev}

        SEQTK_SAMPLE(
            ch_fwd.concat(ch_rev)
        )
        ch_versions = ch_versions.mix(SEQTK_SAMPLE.out.versions.first())
        // combine forward and reverse read channels
        SEQTK_SAMPLE
            .out
            .reads
            .groupTuple(by: 0)
            .concat(ch_reads.ok.map{ [ it.meta, it.reads ] })
            .set{ ch_reads }
    }

    //
    // MODULE: Run FastQC
    //
    FASTQC (
        ch_reads
    )
    ch_versions = ch_versions.mix(FASTQC.out.versions.first())

    //
    // MODULE: Run Fastp
    //
    FASTP (
        ch_reads,
        [],
        false,
        false
    )

    //
    // MODULE: Convert Fastp summary to table format
    //
    FASTP2TBL (
        FASTP.out.json
    )

    /* 
    =============================================================================================================================
        CLASSIFY VIRUSES
    =============================================================================================================================
    */ 

    //
    // SUBWORKFLOW: Classify viruses
    //
    CLASSIFY (
        FASTP
            .out
            .reads
            .join(INPUT_CHECK.out.reads.map{ meta, reads, reference, truth, inter_group, intra_group -> [ meta, reference ] }, by: 0),
        ch_refs
    )

    /* 
    =============================================================================================================================
        ASSEMBLE VIRUSES
    =============================================================================================================================
    */
    // SUBWORKFLOW: Create consensus assemblies
    ASSEMBLE (
        CLASSIFY.out.ref_list.combine(FASTP.out.reads, by: 0)
    )

    /* 
    =============================================================================================================================
        SUMMARIZE RESULTS
    =============================================================================================================================
    */

    // Combine outputs of samples that had references
    ASSEMBLE
        .out
        .samtoolstats2tbl
        .join(ASSEMBLE.out.nextclade, by: [0,1])
        .set{ ch_assembly_list }
    // Create channel of samples with no reference
    if(! CLASSIFY.out.ref_list){
        println "Oh no! All your samples failed! :("
    }
    ch_reads
        .map{ meta, reads -> [ meta ] }
        .join(CLASSIFY.out.ref_list.map{ meta, ref_id, ref -> [ meta, ref_id ] }.ifEmpty([null,null]), by: 0, remainder: true)
        .filter{ meta, ref_id -> ref_id == null}
        .map{ meta, ref_id -> [ meta, "No_Reference", [], [] ] }
        .set{ ch_no_assembly_list }

    // Combine the reference and non-reference channels & add Fastp & Sourmash results
    FASTP2TBL.out.tbl.set{ fastp2tbl }
    CLASSIFY.out.sm_summary.set{ sm_summary }
    ch_assembly_list
      .concat(ch_no_assembly_list)
      .combine(fastp2tbl, by: 0)
      .combine(sm_summary, by: 0)
      .set{ all_list }

    // MODULE: Create summaryline for each sample 
    SUMMARYLINE (
       all_list
           .combine( ch_refsheet )
    )

    // MODULE: Combine summarylines
    SUMMARYLINE
        .out
        .summaryline
        .map{ meta, summaryline -> [ summaryline ] }
        .collect()
        .set{ all_summaries }
    
    COMBINE_SUMMARYLINES (
        all_summaries
    )

    /* 
    =============================================================================================================================
        VALIDATE RESULTS
    =============================================================================================================================
    */

    VALIDATE(
        INPUT_CHECK.out.reads.map{ meta, reads, ref, truth, inter_group, intra_group -> [ meta, truth, inter_group, intra_group ] },
        ASSEMBLE.out.consensus.map{ meta, ref_id, consensus -> [ meta, consensus ] },
        COMBINE_SUMMARYLINES.out.summary
    )

    CUSTOM_DUMPSOFTWAREVERSIONS (
        ch_versions.unique().collectFile(name: 'collated_versions.yml')
    )

    /* 
    =============================================================================================================================
        DEFAULTS
    =============================================================================================================================
    */

    // MODULE: MultiQC
    workflow_summary    = WorkflowVaper.paramsSummaryMultiqc(workflow, summary_params)
    ch_workflow_summary = Channel.value(workflow_summary)

    methods_description    = WorkflowVaper.methodsDescriptionText(workflow, ch_multiqc_custom_methods_description, params)
    ch_methods_description = Channel.value(methods_description)

    ch_multiqc_files = Channel.empty()
    ch_multiqc_files = ch_multiqc_files.mix(ch_workflow_summary.collectFile(name: 'workflow_summary_mqc.yaml'))
    ch_multiqc_files = ch_multiqc_files.mix(ch_methods_description.collectFile(name: 'methods_description_mqc.yaml'))
    ch_multiqc_files = ch_multiqc_files.mix(CUSTOM_DUMPSOFTWAREVERSIONS.out.mqc_yml.collect())
    ch_multiqc_files = ch_multiqc_files.mix(FASTQC.out.zip.collect{it[1]}.ifEmpty([]))

    MULTIQC (
        ch_multiqc_files.collect(),
        ch_multiqc_config.toList(),
        ch_multiqc_custom_config.toList(),
        ch_multiqc_logo.toList()
    )
    multiqc_report = MULTIQC.out.report.toList()
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    COMPLETION EMAIL AND SUMMARY
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow.onComplete {
    if (params.email || params.email_on_fail) {
        NfcoreTemplate.email(workflow, params, summary_params, projectDir, log, multiqc_report)
    }
    NfcoreTemplate.dump_parameters(workflow, params)
    NfcoreTemplate.summary(workflow, params, log)
    if (params.hook_url) {
        NfcoreTemplate.IM_notification(workflow, params, summary_params, projectDir, log)
    }
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
