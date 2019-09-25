#!/bin/bash


k="kubectl"
ns="test-$RANDOM"

echo "Using NS $ns"
$k create ns $ns

echo "Creating FIO profile as ConfigMap"
cat <<END > /tmp/fio-profile
[global]
size=1GB
ioengine=libaio
direct=1
random_generator=tausworthe
random_distribution=random
rw=randrw
rwmixread=60
rwmixwrite=40
percentage_random=85
bs=4k
iodepth=16
log_avg_msec=250
group_reporting=1

[vol0]
filename=/usr/share/nginx/html/v0
END

cat <<END > /tmp/fio-profile2
[global]
size=1GB
ioengine=libaio
direct=1
random_generator=tausworthe
random_distribution=random
rw=randrw
rwmixread=60
rwmixwrite=40
percentage_random=85
bs=32k
iodepth=32
log_avg_msec=250
group_reporting=1

[vol0]
filename=/usr/share/nginx/html/v1
END

$k -n $ns create configmap fio-profile &> /dev/null
$k -n $ns create configmap fio-profile --from-file=/tmp/fio-profile --from-file=/tmp/fio-profile2 -o yaml --dry-run | $k -n $ns replace -f-


echo "Creating a ReadWriteMany volume"
$k create -n $ns -f- <<END
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: shared-vol
  labels:
    storageos.com/replicas: "1"
  annotations:
    volume.beta.kubernetes.io/storage-class: "fast"
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 20Gi
END


echo "Creating NginX deployment"
$k create -n $ns -f- <<END
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deployment
  labels:
    app: nginx
spec:
  replicas: 4
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: arau/tools:nginx-fio
        ports:
        - containerPort: 80
        volumeMounts:
        - name: docroot
          mountPath: /usr/share/nginx/html
        - name: fio-conf
          mountPath: /tmp/profiles
      volumes:
      - name: docroot
        persistentVolumeClaim:
          claimName: shared-vol
      - name: fio-conf
        configMap:
          name: fio-profile
---
apiVersion: v1
kind: Service
metadata:
  name: nginx
  labels:
    app: nginx
spec:
   selector:
    app: nginx
   ports:
   - name: nginx
     port: 80
     targetPort: 80
END

sleep 50

index=/usr/share/nginx/html/index.html

while true; do
    pods="$( $k get pod -n $ns --no-headers -ocustom-columns=_:.metadata.name -lapp=nginx )"
    counter=0
    for p in $pods; do
        echo "Trigger FIO profile1 in $p"
        $k -n $ns exec $p -- /bin/sh -c "fio /tmp/profiles/fio-profile > /usr/share/nginx/html/out-$counter"
        $k -n $ns exec $p -- /bin/sh -c "date >> $index && echo \"<br>\" profile1 \"<br>\" >> $index"
        $k -n $ns exec $p -- /bin/sh -c "grep \"read\\|write\" /usr/share/nginx/html/out-$counter >> $index "
        $k -n $ns exec $p -- /bin/sh -c "echo \"<br>\" >> $index"
        sleep 30
        (( ++counter ))
    done

    counter=0
    for p in $pods; do
        echo "Trigger FIO profile2 in $p"
        $k -n $ns exec $p -- /bin/sh -c "fio /tmp/profiles/fio-profile2 > /usr/share/nginx/html/out2-$counter"
        $k -n $ns exec $p -- /bin/sh -c "date >> $index && echo \"<br>\" profile2 \"<br>\" >> $index"
        $k -n $ns exec $p -- /bin/sh -c "grep \"read\\|write\" /usr/share/nginx/html/out2-$counter >> $index "
        $k -n $ns exec $p -- /bin/sh -c "echo \"<br>\" >> $index"
        sleep 30
        (( ++counter ))
    done


    $k -n $ns exec $pod -- cat $index
    sleep 600
done
