pipeline {
    agent any

    // Builds are started by the GitHub push webhook (GitHub plugin).
    triggers {
        githubPush()
    }

    options {
        timestamps()
        timeout(time: 10, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '20'))
    }

    environment {
        BUILD_DIR = 'build/classes'
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
                sh 'echo "Commit: $(git rev-parse HEAD)"; git log -1 --pretty="Author: %an%nMessage: %s"'
            }
        }

        stage('Environment Verification') {
            steps {
                sh '''
                    set -e
                    echo "Java runtime:"
                    java -version 2>&1
                    echo "Java compiler:"
                    javac -version 2>&1
                '''
            }
        }

        stage('Compile') {
            steps {
                sh '''
                    set -e
                    rm -rf "$BUILD_DIR"
                    mkdir -p "$BUILD_DIR"
                    javac -d "$BUILD_DIR" MatrixMultiplication.java
                    echo "Compiled classes:"
                    ls -1 "$BUILD_DIR"
                '''
            }
        }

        stage('Execute') {
            steps {
                sh 'java -cp "$BUILD_DIR" MatrixMultiplication'
            }
        }
    }

    post {
        success {
            echo 'BUILD RESULT: SUCCESS - MatrixMultiplication compiled and executed.'
        }
        failure {
            echo 'BUILD RESULT: FAILURE - check the stage that failed above.'
        }
        always {
            sh 'rm -rf build'
        }
    }
}
