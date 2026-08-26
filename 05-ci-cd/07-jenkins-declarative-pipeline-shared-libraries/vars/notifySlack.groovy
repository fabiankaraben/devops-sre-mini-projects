def call(Map config = [:]) {
    def channel = config.get('channel', '#ci-cd-notifications')
    def status = config.get('status', 'SUCCESS')
    def buildUrl = env.BUILD_URL ?: 'http://localhost:8080/job/enterprise-ci-pipeline/1/'
    def buildNum = env.BUILD_NUMBER ?: '1'
    def jobName = env.JOB_NAME ?: 'enterprise-ci-pipeline'

    def colorHex = status == 'SUCCESS' ? '#36a64f' : '#dc3545'
    def statusEmoji = status == 'SUCCESS' ? '✅' : '❌'

    echo "\u001B[34m[NOTIFY]\u001B[0m Dispatching ChatOps notification to Slack channel ${channel}..."

    // Simulates sending structured webhook payload while keeping token masked
    sh """
        echo "--> Target Channel: ${channel}"
        echo "--> Status: ${statusEmoji} ${status}"
        echo "--> Build URL: ${buildUrl}"
        echo "--> Webhook Payload Formatted (Color: ${colorHex}, Job: ${jobName} #${buildNum})"
        echo "--> Notification successfully dispatched to Slack webhook."
    """

    echo "\u001B[32m[NOTIFY COMPLETE]\u001B[0m Slack notification published."
}
