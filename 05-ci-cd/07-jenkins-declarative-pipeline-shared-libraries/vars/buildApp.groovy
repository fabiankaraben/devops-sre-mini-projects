def call(Map config = [:]) {
    def buildType = config.get('type', 'nodejs')
    def appDir = config.get('dir', 'app')
    def outputArtifact = config.get('artifact', 'dist/bundle.tar.gz')

    echo "\u001B[34m[BUILD]\u001B[0m Starting application build (type: ${buildType}, directory: ${appDir})..."

    dir(appDir) {
        if (buildType == 'nodejs') {
            sh '''
                echo "--> Node version: $(node -v 2>/dev/null || echo 'Node not found')"
                echo "--> Simulating dependency resolution..."
                mkdir -p dist
                tar -czf dist/bundle.tar.gz src/ package.json 2>/dev/null || tar -czf dist/bundle.tar.gz .
                echo "--> Package artifact generated: dist/bundle.tar.gz ($(ls -lh dist/bundle.tar.gz | awk '{print $5}'))"
            '''
        } else if (buildType == 'python') {
            sh '''
                echo "--> Python version: $(python3 --version 2>/dev/null || echo 'Python not found')"
                mkdir -p dist
                tar -czf dist/bundle.tar.gz src/ requirements.txt 2>/dev/null || tar -czf dist/bundle.tar.gz .
            '''
        } else {
            sh """
                echo "--> Generic build execution..."
                mkdir -p dist
                echo "build-timestamp: \$(date -u)" > dist/build.info
            """
        }
    }

    echo "\u001B[32m[BUILD SUCCESS]\u001B[0m Application packaging completed successfully."
}
