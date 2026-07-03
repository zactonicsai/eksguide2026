@echo off
REM ================================================================
REM  delete-eks-kafka-nifi.bat   (Windows Batch version)
REM
REM  PURPOSE : Tear down an AWS EKS cluster that runs Kafka (Strimzi)
REM            and Apache NiFi, plus the AWS resources they created,
REM            so ALL billing for the cluster stops.
REM
REM  WARNING : THIS PERMANENTLY DESTROYS ALL KAFKA MESSAGES AND ALL
REM            NIFI DATA. There is no undo button.
REM
REM  NEEDS   : aws CLI v2, kubectl, helm, and eksctl on your PATH,
REM            with an AWS profile that has admin permissions.
REM ================================================================

REM ---------- SETTINGS: edit these 4 values for YOUR setup ----------
REM The name of the EKS cluster you want to destroy (the "brain" billed $0.10/hr).
set CLUSTER_NAME=my-eks-cluster
REM The AWS region where the cluster lives.
set REGION=us-east-1
REM The Kubernetes namespace where Strimzi/Kafka was installed.
set KAFKA_NS=kafka
REM The Kubernetes namespace where NiFi was installed.
set NIFI_NS=nifi

REM ---------- SAFETY GATE: make the human prove they mean it ----------
REM Print a big warning so nobody runs this by accident.
echo.
echo  *** DANGER *** This will DELETE cluster "%CLUSTER_NAME%" in %REGION%,
echo  including ALL Kafka messages and ALL NiFi data. No undo.
echo.
REM Ask the user to re-type the cluster name; a wrong answer aborts everything.
set /p CONFIRM=Type the cluster name to confirm: 
REM Compare the answer with the real name; if different, quit without deleting.
if not "%CONFIRM%"=="%CLUSTER_NAME%" (
    echo Names did not match. Nothing was deleted.
    exit /b 1
)

REM ---------- STEP 0: Point kubectl at THIS cluster ----------
REM Downloads the cluster's login info so every kubectl command below
REM talks to this cluster and not some other one. (Free - no billing.)
call aws eks update-kubeconfig --name %CLUSTER_NAME% --region %REGION%

REM ---------- STEP 1: Delete Kafka INSIDE Kubernetes FIRST ----------
REM Why first? While the Strimzi operator is still alive, it politely
REM tells AWS to remove the load balancers ($16-25/mo EACH) and EBS
REM disks ($0.08/GB-mo) it created. Skip this and those bill forever.

REM Delete Kafka users (their passwords/TLS certs are Kubernetes Secrets).
kubectl delete kafkauser --all -n %KAFKA_NS% --ignore-not-found=true 2>nul
REM Delete Kafka topics (the "mailboxes" whose messages sit on EBS disks).
kubectl delete kafkatopic --all -n %KAFKA_NS% --ignore-not-found=true 2>nul
REM Delete Kafka Connect / MirrorMaker2 / Bridge (extra pods burning EC2 time).
kubectl delete kafkaconnect,kafkamirrormaker2,kafkabridge --all -n %KAFKA_NS% --ignore-not-found=true 2>nul
REM Delete the Kafka cluster itself: broker + controller pods vanish AND
REM Strimzi asks AWS to remove the PER-BROKER load balancers (a 3-broker
REM cluster with external listeners has 4 of them: 3 brokers + bootstrap).
kubectl delete kafka --all -n %KAFKA_NS% --ignore-not-found=true 2>nul
REM Delete the node pool definitions (newer Strimzi splits brokers into pools).
kubectl delete kafkanodepool --all -n %KAFKA_NS% --ignore-not-found=true 2>nul
REM Delete any leftover rebalance requests (Cruise Control instructions).
kubectl delete kafkarebalance --all -n %KAFKA_NS% --ignore-not-found=true 2>nul
REM Give AWS about 2 minutes to actually tear the Kafka load balancers down.
timeout /t 120 /nobreak >nul
REM Remove the Strimzi operator itself (just pods - it billed only EC2 time).
call helm uninstall strimzi-cluster-operator -n %KAFKA_NS% 2>nul
REM Delete leftover PersistentVolumeClaims: EACH ONE is a real EBS disk in
REM AWS that keeps billing ~$0.08/GB-month until it is gone.
kubectl delete pvc --all -n %KAFKA_NS% --ignore-not-found=true 2>nul

REM ---------- STEP 2: Delete NiFi INSIDE Kubernetes ----------
REM Remove the NiFi Helm release: deletes the NiFi pods (EC2 usage) and
REM the web-UI Service, which tells AWS to delete NiFi's load balancer.
REM (If your release has a different name, run: helm list -n %NIFI_NS%)
call helm uninstall nifi -n %NIFI_NS% 2>nul
REM If NiFi used its own ZooKeeper release for clustering, remove it too
REM (more pods + more EBS disks that would otherwise keep billing).
call helm uninstall zookeeper -n %NIFI_NS% 2>nul
REM Delete any Ingress objects: each Ingress = a real AWS ALB (~$17+/mo).
kubectl delete ingress --all -n %NIFI_NS% --ignore-not-found=true 2>nul
REM Delete NiFi's disks: the FlowFile, Content, and Provenance repositories
REM each live on EBS volumes that bill until their PVCs are deleted.
kubectl delete pvc --all -n %NIFI_NS% --ignore-not-found=true 2>nul

REM ---------- STEP 3: Delete the namespaces (final inside sweep) ----------
REM Deleting a namespace deletes EVERY leftover object inside it (services,
REM secrets, configmaps) so no hidden LoadBalancer service survives.
kubectl delete namespace %KAFKA_NS% %NIFI_NS% --ignore-not-found=true 2>nul
REM Give the AWS Load Balancer Controller time to finish AWS-side cleanup.
timeout /t 120 /nobreak >nul

REM ---------- STEP 4: Delete the EKS cluster itself ----------
REM eksctl removes: managed node groups (the EC2 computers), the control
REM plane (the ~$73/month "brain" fee), and - if eksctl created it - the
REM VPC along with its NAT gateway (~$33/month) and public IPv4 addresses.
call eksctl delete cluster --name %CLUSTER_NAME% --region %REGION% --wait
REM If the cluster was NOT built with eksctl (console/Terraform/CDK),
REM comment out the line above and use these instead (repeat the
REM delete-nodegroup line for every name that list-nodegroups prints):
REM call aws eks list-nodegroups --cluster-name %CLUSTER_NAME% --region %REGION%
REM call aws eks delete-nodegroup --cluster-name %CLUSTER_NAME% --nodegroup-name MY_NODEGROUP --region %REGION%
REM call aws eks delete-cluster --name %CLUSTER_NAME% --region %REGION%
REM (That path does NOT delete a shared VPC/NAT - review those by hand.)

REM ---------- STEP 5: Hunt down orphaned EBS disks ----------
REM Any disk still tagged with our cluster and sitting "available" (attached
REM to nothing) is a zombie that silently bills $0.08/GB-month forever.
set ORPHAN_VOLS=
REM Ask AWS for the IDs of all zombie disks tagged with this cluster.
for /f "delims=" %%A in ('aws ec2 describe-volumes --region %REGION% --filters "Name=tag-key,Values=kubernetes.io/cluster/%CLUSTER_NAME%" "Name=status,Values=available" --query "Volumes[].VolumeId" --output text') do set ORPHAN_VOLS=%%A
REM Delete each zombie disk found above (this loop is skipped if none exist).
if defined ORPHAN_VOLS for %%V in (%ORPHAN_VOLS%) do (
    echo Deleting leftover EBS disk %%V
    aws ec2 delete-volume --volume-id %%V --region %REGION%
)

REM ---------- STEP 6: Delete CloudWatch log groups ----------
REM Stored logs bill ~$0.03/GB-month FOREVER until the groups are deleted.
REM The EKS control plane's own log group (audit/api logs):
aws logs delete-log-group --log-group-name /aws/eks/%CLUSTER_NAME%/cluster --region %REGION% 2>nul
REM Container Insights log groups (exist only if monitoring was enabled) -
REM these held Kafka broker logs and chatty NiFi app logs:
aws logs delete-log-group --log-group-name /aws/containerinsights/%CLUSTER_NAME%/application --region %REGION% 2>nul
aws logs delete-log-group --log-group-name /aws/containerinsights/%CLUSTER_NAME%/dataplane --region %REGION% 2>nul
aws logs delete-log-group --log-group-name /aws/containerinsights/%CLUSTER_NAME%/host --region %REGION% 2>nul
aws logs delete-log-group --log-group-name /aws/containerinsights/%CLUSTER_NAME%/performance --region %REGION% 2>nul

REM ---------- STEP 7 (OPTIONAL): things we do NOT auto-delete ----------
REM ECR repositories (your custom NiFi / Kafka Connect images) bill
REM $0.10/GB-month. Un-comment and edit the next line to remove one:
REM aws ecr delete-repository --repository-name my-custom-nifi --force --region %REGION%
REM EBS snapshots (disk backups) bill ~$0.05/GB-month - review them with:
REM aws ec2 describe-snapshots --owner-ids self --region %REGION%

REM ---------- DONE ----------
echo.
echo Teardown finished. In the AWS console, double-check for leftovers:
echo   EC2  ^> Load Balancers, Target Groups, Volumes, Elastic IPs
echo   VPC  ^> NAT Gateways (only if your VPC was NOT created by eksctl)
echo   ECR  ^> old image repositories
echo When those pages are empty for this cluster, the meter has stopped.
