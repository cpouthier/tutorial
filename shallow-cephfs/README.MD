# Set up your environement to benefit from CephFS Shallow Volumes

Veeam Kasten supports the use of snapshots as shallow read-only volumes specifically designed for file systems (FS), particularly for the CephFS CSI driver.
It provides faster snasphots capabilities on the Ceph FS side.
You'll find here a step-by-step tutorial on how you can integrate shallow read-only volumes in your environement and setup your Veeam Kasten backup policy accordingly.

## Setup a new storage class

This storage class will be used by Veeam Kasten to create a cloned PVC from the snapshot created from the original PVC of your application.

To proceed, create a clone of your original CephFS storage class and add in the parameter section add backingSnapshot: "true":

`
parameters:
  backingSnapshot: "true"
`

To allow Veeam Kasten to mount as Read-Only your application PVC's snapshot you'll need to add an annotation to this newly created storage class:

```shell
kubectl annotate storageclass $SHALLOW_CSI_STORAGE_CLASS \
    k10.kasten.io/sc-supports-read-only-mount="true"
```
## Setup a test application

Create a PVC in a new namespace on the existing CephFS storage class:

```shell
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
   name: original-pvc
   namespace: $NEW_NAMESPACE
spec:
   accessModes:
      - ReadWriteOnce
   resources:
      requests:
         storage: 3Gi
   storageClassName: $EXISTING_CEPH_FS_STORAGE_CLASS`
```

Create a pod in this namespace, mount the PVC and create a test file:

```shell
apiVersion: v1
kind: Pod
metadata:
  creationTimestamp: null
  labels:
    run: pod-on-original-pvc
  name: pod-on-original-pvc
  namespace: $NEW_NAMESPACE
spec:
  dnsPolicy: ClusterFirst
  restartPolicy: Always
  initContainers:
  - image: alpine:3.7
    name: init-pod-on-original-pvc
    resources: {}
    command: 
    - sh
    - -o
    - errexit
    - -c
    - | 
      echo "test data" > /data/test-file
    volumeMounts:
    - name: data
      mountPath: /data
  containers:
  - image: alpine:3.7
    name: pod-on-original-pvc
    resources: {}
    command: ["tail"]
    args: ["-f", "/dev/null"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: original-pvc
status: {}`
```
## Test the backup of your namespace with Veeam Kasten

Create a policy (snapshot) in Veeam Kasten as you would do usually and select "Enable backups via snapshot exports". Select the location profile where you want to export your backup and click on the "Advanced Export Settings".
A new panel will open on the left.
In the "Exporter Storage Class Name" provide the $SHALLOW_CSI_STORAGE_CLASS name, click on "Add new override" and in the "Storage Class Name Override" provide the $EXISTING_CEPH_FS_STORAGE_CLASS name.
Save your policy and execute it.

This will actually add in the policy:
```shell
exportData:
  enabled: true
  overrides:
    - storageClassName: $EXISTING_CEPH_FS_STORAGE_CLASS
      enabled: true
      exporterStorageClassName: $SHALLOW_CSI_STORAGE_CLASS
```
