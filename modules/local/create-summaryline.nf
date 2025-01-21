process SUMMARYLINE {
    tag "$meta.id"
    label 'process_low'

    input:
    tuple val(meta), val(ref_id), path(bam_stats), path(nextclade), path(fastp_json), val(sm_summary), path(refsheet)

    output:
    tuple val(meta), path("*.summaryline.csv"), emit: summaryline
    path "versions.yml",                        emit: versions


    when:
    task.ext.when == null || task.ext.when

    prefix = task.ext.prefix ?: "${meta.id}"
    script:
    """
    # format reports to tables
    ## Fastp
    fastp2tbl.sh ${fastp_json} > ${prefix}.fastp2tbl.csv
    ## Mapping stats
    samtoolstats2tbl.sh ${bam_stats} > ${prefix}.samtoolstats2tbl.csv

    # create summaryline
    summaryline.R ${prefix}.fastp2tbl.csv "${sm_summary}" ${prefix}.samtoolstats2tbl.csv "${nextclade}" "${prefix}" "${ref_id}" "${refsheet}"
    # rename using prefix and reference
    mv summaryline.csv "${prefix}-${ref_id}.summaryline.csv"
    
    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        summaryline.R: \$(summaryline.R version)
    END_VERSIONS
    """
}
