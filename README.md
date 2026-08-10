![alt text](https://raw.githubusercontent.com/cpouthier/tutorial/main/k10gh.png)
# Tutorial
The aim of this tutorial is to guide you through a full deployment of Kasten on a single node K3s running on a Linux VM (tested with Ubuntu 24.04).
K3s is a lightweight distribution of Kubernetes (K8s).

All scripts are inspired (and copied) from my fellow colleague James Tate (https://blog.kodu.uk/kasten-k10-guide-for-beginners-part-2/)

Please have a read to this entire tutorial before setting up your environment.
## Pre-requisites
The main pre-requisite is obviously to get a VM or bare metal server with Linux installed and superuser access. The superuser access (su) will be used in order to run scipts below and the fdisk utility to **provide a new free partition** (fdisk -l or fidsk /dev/xxx) we will format later on in zfs.

You also need to ensure to get **at least 8GB of free memory and about 100GB of disk** to install all the tools, K3s, Minio...
All instructions below will be run as superuser (sudo su).
## Setup the environement
**Before doing anything use the fdisk utility in order to provide (or ensure) you'll get a fresh free new unformatted disk partition.**

Then, let's tune a little bit your Linux environement:
```console
sed -i 's/#$nrconf{restart} = '"'"'i'"'"';/$nrconf{restart} = '"'"'a'"'"';/g' /etc/needrestart/needrestart.conf
apt update
sysctl fs.inotify.max_user_watches=524288
sysctl fs.inotify.max_user_instances=512
echo "fs.inotify.max_user_watches = 524288" >> /etc/sysctl.conf
echo "fs.inotify.max_user_instances = 512" >> /etc/sysctl.conf
apt install apache2-utils -y
```
## Setup some environment variables
Now we need to set up some environement variables that we will use later in this tutorial. Veeam Kasten will be installed with basic authentication, hence the need to provide a username and a password. Same credentials will be used too to connect to Minio:
```console
echo "Kasten will be installed with basic authentication, hence the need to provide a username and a password."
echo "You will use also those credentials to connect to Minio."
echo -e "\033[0;31m Enter the username: \e[0m"
read username < /dev/tty
echo -e "\033[0;31m Enter the password: \e[0m"
read password < /dev/tty
htpasswd_entry=$(htpasswd -nbm "$username" "$password" | cut -d ":" -f 2)
htpasswd="$username:$htpasswd_entry"
echo "Successfully generated htpasswd entry: $htpasswd"
sleep 3
```
**WARNING: ensure you do not exit your console otherwise you'll loose those variable and you won't be able to perform a clean install with all instructions below!**

We also need to get the fresh new partition you created with fdisk utility to set up the zfs pool we will use to provide snapshot compatible storage to K3s.
```console
fdisk -l
echo ""
echo -e "\033[0;31m Enter partition path of extra volume (ie /dev/sdbx) to set up Kasten K10 zfs pool: \e[0m"
read DRIVE < /dev/tty
```

Additionnaly specify the name of this cluster, the storage class name you wish to customize, an email address (used for Let's Encrypt expiry notices and the Kasten EULA), and whether you also want to deploy the optional Addressbook demo app (see [Install the Addressbook demo app](#optional-install-the-addressbook-demo-app) below).

```console
echo -e "\033[0;31m Enter name of this cluster: \e[0m"
read cluster_name < /dev/tty
echo -e "\033[0;31m Customize the name you would like to use for the storage class: \e[0m"
read sc_name < /dev/tty
echo -e "\033[0;31m Enter an email address (used for Let's Encrypt expiry notices and the Kasten EULA): \e[0m"
read admin_email < /dev/tty
echo -e "\033[0;31m (Optional) Deploy the Addressbook demo app too? A minimal name+address form backed by a 1Gi PVC, handy to test Kasten backup/restore on a small stateful app (y/n): \e[0m"
read deploy_addressbook < /dev/tty
echo ""
```

# Install some tools
## Install Helm
First of all we will install Helm which is a packet manager for Kubernetes:
```console
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod +x ./get_helm.sh
./get_helm.sh
```
## Install Kubectl
Then we need to install Kubectl which is the command line tool to communicate with Kubernetes and add autocompletion in bash. We'll also add an alias (k) to simplify further interaction in bash:
```console
curl -LO https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl
chmod +x ./kubectl
sudo mv ./kubectl /usr/local/bin/kubectl
echo 'source <(kubectl completion bash)' >>~/.bashrc
source <(kubectl completion bash)
echo "alias k=kubectl" | tee -a /root/.bashrc
alias k=kubectl
```
# Installing K3s
K3s will be installed as a single node cluster. We will disable traefik (default ingress controller) as we'll use nginx.
## Install K3s
```console
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable local-storage --disable=traefik" sh -s -
mkdir /root/.kube
cp /etc/rancher/k3s/k3s.yaml /root/.kube/config
chmod 600 ~/.kube/config && export KUBECONFIG=~/.kube/config
```
Wait 30 seconds in order for K3s to spin up and check the status:
```console
k3s check-config
kubectl cluster-info
kubectl get nodes -o wide
```
## Configure storage 
As already said, we will configure a ZFS storage pool which will provide snapshot functionnality for our kubernetes applications deployed on this K3s cluster.

### Install zfs and configure kasten-pool storage pool on associated drive
```console
apt install zfsutils-linux open-iscsi jq -y
if ! zpool create kasten-pool "$DRIVE"; then
  echo -e "\033[0;31m ERROR: zpool create failed on $DRIVE — check the drive path (fdisk -l above) and re-run this script.\e[0m"
  exit 1
fi
```
### Configure zfs storage class
```console
kubectl apply -f https://openebs.github.io/charts/zfs-operator.yaml
echo "Waiting for the ZFS CSI driver pods to be ready..."
kubectl wait --for=condition=ready pod -l app=openebs-zfs-controller -n kube-system --timeout=120s
kubectl wait --for=condition=ready pod -l app=openebs-zfs-node -n kube-system --timeout=120s
echo | kubectl apply -f - << EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: $sc_name
parameters:
  recordsize: "4k"
  compression: "off"
  dedup: "off"
  fstype: "zfs"
  poolname: "kasten-pool"
provisioner: zfs.csi.openebs.io
EOF
```
### Configure zfs Volume Snaspshot class
```console
echo | kubectl apply -f - << EOF
kind: VolumeSnapshotClass
apiVersion: snapshot.storage.k8s.io/v1
metadata:
  name: $sc_name-zfs-snapclass
  annotations:
    snapshot.storage.kubernetes.io/is-default-class: "true"
    k10.kasten.io/is-snapshot-class: "true"
driver: zfs.csi.openebs.io
deletionPolicy: Delete
EOF
```


### Annotate the Storage Class
```console
kubectl patch storageclass $sc_name -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```
# Installing Nginx
We will now install Nginx as our ingress controller for our K3s cluster:
```console
helm upgrade --install ingress-nginx ingress-nginx --repo https://kubernetes.github.io/ingress-nginx --namespace nginx --create-namespace
```
# Installing Minio
Now we will perform Minio installation outside of K3s. Minio will provide S3 object storage which will be used as external repository to export Kasten backups.
```console
wget https://dl.min.io/server/minio/release/linux-amd64/minio -P /root
chmod +x /root/minio
mv /root/minio /usr/local/bin
mkdir /minio
MINIO_ROOT_USER=$username MINIO_ROOT_PASSWORD=$password minio server /minio --console-address ":9001" &
echo "@reboot MINIO_ROOT_USER=$username MINIO_ROOT_PASSWORD=$password minio server /minio --console-address ":9001"" > /root/minio_cron
crontab /root/minio_cron
get_ip=$(hostname -I | awk '{print $1}')
curl -L https://dl.min.io/client/mc/release/linux-amd64/mc \
  --create-dirs \
  -o $HOME/minio-binaries/mc
chmod +x $HOME/minio-binaries/mc
export PATH=$PATH:$HOME/minio-binaries/
```
A bad download (e.g. a redirect page saved instead of the real `mc` binary) fails silently otherwise, so we validate it before using it:
```console
if ! $HOME/minio-binaries/mc --version >/dev/null 2>&1; then
  echo -e "\033[0;31m ERROR: the downloaded mc binary isn't valid — check your network/proxy and re-run this script.\e[0m"
  exit 1
fi

mc alias set my-minio http://127.0.0.1:9000 $username $password
```
## (Optional) Bucket creation
With the command below, you can optionnaly create the bucket we will use and configure in Kasten automatically. The `my-minio` alias was already created above.
We will create now a standard S3 bucket:
```console
mc mb my-minio/s3-standard-$cluster_name
```
# Veeam Kasten installation
This is actually my favourite part!
## Add and update Helm repository
```console
helm repo add kasten https://charts.kasten.io
helm repo update
```
## Running pre-flight checks
Running pre-flight checks (also referred as primer) is a way to enure that you'll be able install properly Veeam Kasten on your environment:
```console
curl https://docs.kasten.io/tools/k10_primer.sh | bash
```
Pay attention to the output in order to fix any problem before proceeding to Veeam Kasten installation.

## Create the namespace for Veeam Kasten
```console
kubectl create ns kasten-io
```
## Install Kasten
Kasten will be installed in the kasten-io namespace with basic authentication:
```console
helm install k10 kasten/k10 --namespace kasten-io --set "auth.basicAuth.enabled=true" --set auth.basicAuth.htpasswd=$htpasswd
```
Other Helm options are available here: https://docs.kasten.io/latest/install/advanced.html?highlight=advanced#complete-list-of-k10-helm-options

Before going further, wait for all Kasten pods to become ready:
```console
until [ "$(kubectl get pods -n kasten-io --no-headers 2>/dev/null | wc -l)" -gt 0 ]; do
  sleep 2
done
kubectl wait --for=condition=ready pod --all -n kasten-io --timeout=600s
```
## Expose Kasten over HTTPS
Kasten's auth cookie has the `Secure` flag, so login only works over real HTTPS — plain HTTP access via a LoadBalancer on port 8000 (and a `kasten.local` host that doesn't resolve anywhere) causes an infinite auth redirect loop: basic-auth succeeds, but the session cookie is never stored/sent back.

Instead, we terminate TLS via nginx-ingress with a real Let's Encrypt certificate (cert-manager), using a [nip.io](https://nip.io) hostname that resolves to your server's IP automatically — no domain to buy, no `/etc/hosts` entry to add on every client.
```console
nip_host="kasten.$(echo $get_ip | tr '.' '-').nip.io"
```
### Install cert-manager
```console
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set installCRDs=true
kubectl -n cert-manager rollout status deployment/cert-manager --timeout=180s
kubectl -n cert-manager rollout status deployment/cert-manager-webhook --timeout=180s
kubectl -n cert-manager rollout status deployment/cert-manager-cainjector --timeout=180s
```
### Create the Let's Encrypt ClusterIssuer
This uses the HTTP-01 challenge, served through nginx:
```console
echo | kubectl apply -f - << EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: $admin_email
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
      - http01:
          ingress:
            ingressClassName: nginx
EOF
```
### Allow the cert-manager HTTP-01 solver through Kasten's NetworkPolicy
Kasten's Helm chart ships a "default-deny" NetworkPolicy for its own namespace (security hardening). cert-manager's HTTP-01 solver pod gets created in this same namespace (since that's where the Ingress below lives), so it inherits that deny and its challenge gets silently blocked unless explicitly allowed — without this, the certificate request hangs in "pending" forever with a "connection refused" on the solver pod.
```console
echo | kubectl apply -f - << EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-cert-manager-http01-solver
  namespace: kasten-io
spec:
  podSelector:
    matchLabels:
      acme.cert-manager.io/http01-solver: "true"
  policyTypes:
    - Ingress
  ingress:
    - {}
EOF
```
### Set up the Kasten ingress
This uses the real nip.io hostname, reachable from anywhere with no client-side DNS/hosts configuration:
```console
echo | kubectl apply -f - << EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: k10-ingress
  namespace: kasten-io
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - $nip_host
      secretName: kasten-tls-letsencrypt
  rules:
    - host: $nip_host
      http:
        paths:
          - pathType: Prefix
            path: "/"
            backend:
              service:
                name: gateway
                port:
                  number: 8000
EOF
```
Wait for Let's Encrypt to issue the certificate (can take 1-2 minutes):
```console
for i in $(seq 1 30); do
  kubectl -n kasten-io get secret kasten-tls-letsencrypt >/dev/null 2>&1 && break
  sleep 5
done
kubectl -n kasten-io get certificate kasten-tls-letsencrypt
```
## (Optional) Pre-populate Kasten

All the optional scripts belows are intended to automate and pre-populate Kasten in order to quickly deploy everything you need. 

You can also use them as an example for your future deployments and industrialize things, but keep in mind that everything can be managed **directly and easily in the web GUI of Kasten**.
### Accept EULA
```console
echo | kubectl apply -f - << EOF
apiVersion: v1
data:
  accepted: "true"
  company: MyBigCompany
  email: $admin_email
kind: ConfigMap
metadata:
  name: k10-eula-info
  namespace: kasten-io
EOF
```
### Create location profiles in Kasten
#### Create the Minio access key and secret
##### Create Minio access key
```console
minio_access_key_id=$(echo $username)
minio_access_key_secret=$(echo $password)
```
##### Create Minio secret for Veeam Kasten
```console
kubectl create secret generic k10-s3-secret-minio \
      --namespace kasten-io \
      --type secrets.kanister.io/aws \
      --from-literal=aws_access_key_id=$minio_access_key_id\
      --from-literal=aws_secret_access_key=$minio_access_key_secret
```
#### Create Location profile for Minio standard bucket
```console
echo | kubectl apply -f - << EOF
apiVersion: config.kio.kasten.io/v1alpha1
kind: Profile
metadata:
  name: s3-standard-bucket-$cluster_name
  namespace: kasten-io
spec:
  locationSpec:
    objectStore:
      objectStoreType: S3
      name: s3-standard-$cluster_name
      region: eu
      endpoint: http://$get_ip:9000
      skipSSLVerify: true
    type: ObjectStore
    credential:
      secretType: AwsAccessKey
      secret:
        apiVersion: v1
        kind: Secret
        name: k10-s3-secret-minio
        namespace: kasten-io
  type: Location
EOF
```

# Install S3UI
S3UI is a small web UI to browse and manage Minio buckets from a browser, handy since Minio's own console isn't always convenient to expose. We'll deploy it on the same K3s cluster and expose it over HTTPS the same way as Kasten, reusing the `letsencrypt-prod` ClusterIssuer and `nginx-ingress` already set up above (ClusterIssuers aren't namespaced, so there's nothing to recreate).
```console
s3ui_nip_host="s3ui.$(echo $get_ip | tr '.' '-').nip.io"
```
## Deploy the Namespace, Deployment, Service and Ingress
```console
echo | kubectl apply -f - << EOF
apiVersion: v1
kind: Namespace
metadata:
  name: s3ui
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: s3ui
  namespace: s3ui
spec:
  replicas: 1
  selector:
    matchLabels:
      app: s3ui
  template:
    metadata:
      labels:
        app: s3ui
    spec:
      containers:
        - name: s3ui
          image: cpouthier/s3ui:latest
          imagePullPolicy: Always
          ports:
            - containerPort: 8000
          envFrom:
            - secretRef:
                name: s3ui-config
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 256Mi
          readinessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 15
            periodSeconds: 30
---
apiVersion: v1
kind: Service
metadata:
  name: s3ui
  namespace: s3ui
spec:
  selector:
    app: s3ui
  ports:
    - port: 80
      targetPort: 8000
  type: ClusterIP
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: s3ui-ingress
  namespace: s3ui
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - $s3ui_nip_host
      secretName: s3ui-tls-letsencrypt
  rules:
    - host: $s3ui_nip_host
      http:
        paths:
          - pathType: Prefix
            path: "/"
            backend:
              service:
                name: s3ui
                port:
                  number: 80
EOF
```
The Service is `ClusterIP` rather than `LoadBalancer`: this VM has no MetalLB, and `nginx-ingress` already owns the node's public IP on 80/443, so we route to S3UI through the Ingress instead of requesting a second LoadBalancer IP.
## Wire up S3UI with the Minio credentials
We reuse the same Minio credentials already used above for Kasten's location profile (`$minio_access_key_id` / `$minio_access_key_secret`) — a single source of truth, nothing to duplicate by hand:
```console
kubectl create secret generic s3ui-config -n s3ui \
  --from-literal=MINIO_ENDPOINT="${get_ip}:9000" \
  --from-literal=MINIO_ACCESS_KEY="${minio_access_key_id}" \
  --from-literal=MINIO_SECRET_KEY="${minio_access_key_secret}" \
  --from-literal=MINIO_SECURE=false \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n s3ui rollout restart deployment/s3ui
kubectl -n s3ui rollout status deployment/s3ui --timeout=120s
```
Wait for Let's Encrypt to issue the certificate (can take 1-2 minutes):
```console
for i in $(seq 1 30); do
  kubectl -n s3ui get secret s3ui-tls-letsencrypt >/dev/null 2>&1 && break
  sleep 5
done
kubectl -n s3ui get certificate
```

# (Optional) Install the Addressbook demo app
A deliberately minimal app: a page with a "Name" + "Postal address" form, every stored entry listed right below on the same page, and buttons to clear the database or reset it back to 10 pre-populated fictitious entries. Its "database" is a single SQLite file on its own 1Gi PVC — no separate database Deployment/Service/Secret — which makes it a small, easy-to-understand stateful workload for trying out Kasten backup/restore without the moving parts of a full database.

This step only runs if you answered `y` to the Addressbook prompt above:
```console
if [[ "$deploy_addressbook" =~ ^[Yy]$ ]]; then
  addressbook_nip_host="addressbook.$(echo $get_ip | tr '.' '-').nip.io"
```
## Deploy the Namespace, PVC, Deployment, Service and Ingress
Reuses the same `letsencrypt-prod` ClusterIssuer and `nginx-ingress` already set up for Kasten and S3UI above, and the `$sc_name` storage class created earlier:
```console
  echo | kubectl apply -f - << EOF
apiVersion: v1
kind: Namespace
metadata:
  name: addressbook
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: addressbook-data
  namespace: addressbook
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: $sc_name
  resources:
    requests:
      storage: 1Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: addressbook
  namespace: addressbook
spec:
  strategy:
    type: Recreate
  replicas: 1
  selector:
    matchLabels:
      app: addressbook
  template:
    metadata:
      labels:
        app: addressbook
    spec:
      containers:
        - name: addressbook
          image: cpouthier/addressbook:latest
          imagePullPolicy: Always
          ports:
            - containerPort: 8000
          env:
            - name: DB_PATH
              value: /data/addressbook.db
          volumeMounts:
            - name: data
              mountPath: /data
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 256Mi
          readinessProbe:
            httpGet:
              path: /ready
              port: 8000
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 15
            periodSeconds: 30
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: addressbook-data
---
apiVersion: v1
kind: Service
metadata:
  name: addressbook
  namespace: addressbook
spec:
  selector:
    app: addressbook
  ports:
    - port: 80
      targetPort: 8000
  type: ClusterIP
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: addressbook-ingress
  namespace: addressbook
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - $addressbook_nip_host
      secretName: addressbook-tls-letsencrypt
  rules:
    - host: $addressbook_nip_host
      http:
        paths:
          - pathType: Prefix
            path: "/"
            backend:
              service:
                name: addressbook
                port:
                  number: 80
EOF
```
`strategy: Recreate` (not the default `RollingUpdate`) is required because the PVC is `ReadWriteOnce` — a second pod can't mount it until the first one releases it, so a rolling update would otherwise leave a new pod stuck `Pending` forever.

## Wait for it to be ready
```console
  kubectl -n addressbook rollout status deployment/addressbook --timeout=120s

  echo "Waiting for the Let's Encrypt certificate for Addressbook (can take 1-2 minutes)..."
  for i in $(seq 1 30); do
    kubectl -n addressbook get secret addressbook-tls-letsencrypt >/dev/null 2>&1 && break
    sleep 5
  done
  kubectl -n addressbook get certificate
fi
```

# Final stage
We will now save all credentials and URLs in a file for further reference and clean up
```console
cat <<EOF > credentials
Kasten k10 can be accessed on https://$nip_host/k10/#/ using credentials ($username/$password)
Minio console is available on  http://$get_ip:9001, with the same username/password.
    Minio has been configured with 1 bucket and according location profile has been created in Kasten:
        - s3-standard
    It can be accessed through API on http://$get_ip:9000 using credentials ($username/$password)
S3UI (a web UI for Minio) can be accessed on https://$s3ui_nip_host using the same credentials ($username/$password)
Your storage class name is $sc_name on this cluster $cluster_name.
EOF
if [[ "$deploy_addressbook" =~ ^[Yy]$ ]]; then
  echo "Addressbook (demo app) is accessible at https://$addressbook_nip_host" >> credentials
fi
rm get_helm.sh
clear
echo ""
echo ""
echo -e "\033[0;32m Congratulations\e[0m"
echo -e "\033[0;32m You can now use Veeam Kasten and all its features!\e[0m"
echo ""
echo ""
echo "Kasten k10 can be accessed on https://$nip_host/k10/#/ using credentials ($username/$password)."
echo "Minio console is available on  http://$get_ip:9001, with the same username/password."
echo "    Minio has been configured with 1 bucket and according location profile has been created in Kasten:"
echo "        - s3-standard"
echo "    It can be accessed through API on http://$get_ip:9000 using credentials ($username/$password)"
echo "S3UI (a web UI for Minio) can be accessed on https://$s3ui_nip_host using the same credentials ($username/$password)"
if [[ "$deploy_addressbook" =~ ^[Yy]$ ]]; then
  echo "Addressbook (demo app) is accessible at https://$addressbook_nip_host"
fi
echo "Your storage class name is $sc_name on this cluster $cluster_name"
```
# One more thing...
If you're already fed up with the idea to spend time to copy/paste instructions, just run the command below as superuser (sudo su), it will take roughly 10 min to set up everything (interactive), but not sure you'll learn something (you'll need however to do the fdisk part manually before running this script):
```console
curl -s https://raw.githubusercontent.com/cpouthier/tutorial/main/installscript.sh | bash
```
