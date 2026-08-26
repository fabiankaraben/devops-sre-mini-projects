package org.devops

class PipelineLogger implements Serializable {
    private Object script

    PipelineLogger(Object script) {
        this.script = script
    }

    void info(String message) {
        script.echo "\u001B[34m[INFO]\u001B[0m ${message}"
    }

    void success(String message) {
        script.echo "\u001B[32m[SUCCESS]\u001B[0m ${message}"
    }

    void warn(String message) {
        script.echo "\u001B[33m[WARNING]\u001B[0m ${message}"
    }

    void error(String message) {
        script.echo "\u001B[31m[ERROR]\u001B[0m ${message}"
    }

    void section(String title) {
        script.echo "\u001B[1;36m======================================================================\u001B[0m"
        script.echo "\u001B[1;36m  🚀 ${title}\u001B[0m"
        script.echo "\u001B[1;36m======================================================================\u001B[0m"
    }
}
