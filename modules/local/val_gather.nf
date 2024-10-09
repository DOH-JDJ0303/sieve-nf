process GATHER {
    label 'process_low'
    tag "${fasta.baseName}-${metric}-${precision_type}"

    conda "bioconda::mafft=7.520"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/mafft:7.520--h031d066_3':
        'biocontainers/mafft:7.520--h031d066_3' }"

    input:
    tuple val(metric), val(precision_type), path(fasta)

    output:
    tuple val(metric), val(precision_type), path("*.csv"),  emit: result
    path "*.aln",                                           emit: aln
    path "versions.yml",                                    emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args   ?: ''
    """
    mafft --auto ${fasta} > ${fasta.baseName}.aln
    val_gather.sh ${fasta.baseName}.aln "${metric}" "${fasta.baseName.tokenize(".")[1]}" "${fasta.baseName.tokenize(".")[0]}"

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        mafft: \$(mafft --version 2>&1 | sed 's/^v//' | sed 's/ (.*)//')
    END_VERSIONS
    """

}
