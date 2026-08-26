def call(Map config = [:]) {
    def appName = config.get('appName', 'cart-service')
    def buildType = config.get('buildType', 'nodejs')
    def agentImage = config.get('agentImage', 'node:20-alpine')
    def targetChannel = config.get('slackChannel', '#deployments')
    def appDir = config.get('dir', 'app')
    def minCoverage = config.get('minCoverage', 80)

    pipeline {
        agent {
            docker {
                image agentImage
                reuseNode true
                args '-u 0:0'
            }
        }

        options {
            timeout(time: 15, unit: 'MINUTES')
            buildDiscarder(logRotator(numToKeepStr: '10'))
            ansiColor('xterm')
            timestamps()
            disableConcurrentBuilds()
        }

        environment {
            APPLICATION_NAME = "${appName}"
            BUILD_ENVIRONMENT = "production"
            SECRET_API_KEY = credentials('secret-api-key')
            SLACK_TOKEN = credentials('slack-webhook-token')
        }

        stages {
            stage('1. Dynamic Agent Inspection') {
                steps {
                    echo "[AGENT] Ephemeral Docker agent active: ${agentImage}"
                    sh '''
                        echo "===> Execution Environment Inside Container <==="
                        echo "Container OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"')"
                        echo "Container User: $(whoami) (UID: $(id -u))"
                        echo "Hostname / Container ID: $(hostname)"
                    '''
                }
            }

            stage('2. Build & Package') {
                steps {
                    echo "[PIPELINE] Invoking Shared Library step: buildApp()..."
                    buildApp(type: buildType, dir: appDir)
                }
            }

            stage('3. Automated Tests & Coverage') {
                steps {
                    echo "[PIPELINE] Invoking Shared Library step: runTests()..."
                    runTests(dir: appDir, minCoverage: minCoverage)
                }
            }

            stage('4. Security & Credential Masking Audit') {
                steps {
                    echo "[PIPELINE] Auditing Jenkins credential masking in console logs..."
                    sh '''
                        echo "===> Credential Masking Verification <==="
                        echo "Attempting to echo secret token: ${SECRET_API_KEY}"
                        echo "Attempting to echo slack token: ${SLACK_TOKEN}"
                        echo "Notice Jenkins console automatically replaces raw secret strings with ****"
                    '''
                }
            }

            stage('5. Deploy Artifact') {
                steps {
                    echo "[PIPELINE] Simulating Zero-Downtime Deployment of ${APPLICATION_NAME}..."
                    sh '''
                        echo "--> Deploying bundle to target environment (${BUILD_ENVIRONMENT})..."
                        echo "--> Healthcheck endpoint: https://${APPLICATION_NAME}.${BUILD_ENVIRONMENT}.internal/health"
                        echo "--> Status: 200 OK (Deployment verified)"
                    '''
                }
            }
        }

        post {
            always {
                echo "[PIPELINE] Invoking Shared Library step: notifySlack()..."
                notifySlack(
                    channel: targetChannel,
                    status: currentBuild.currentResult ?: 'SUCCESS'
                )
                echo "[PIPELINE] Workspace cleanup..."
                deleteDir()
            }
            success {
                echo "\u001B[32m[PIPELINE SUCCESS]\u001B[0m Pipeline run completed with 0 errors!"
            }
            failure {
                echo "\u001B[31m[PIPELINE FAILURE]\u001B[0m Pipeline failed. Triggering incident response."
            }
        }
    }
}
