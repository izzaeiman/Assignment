# Assignment – Java CI with Jenkins and GitHub Webhooks

`MatrixMultiplication.java` is compiled and run automatically by Jenkins on every push.

Flow: **git push → GitHub webhook → Jenkins (`/github-webhook/`) → checkout → `javac` → `java` → build result**

- `Jenkinsfile` – declarative pipeline: Checkout, Environment Verification, Compile, Execute.
- Jenkins runs on an AWS EC2 Ubuntu instance with OpenJDK 21, behind a Caddy HTTPS reverse proxy.
