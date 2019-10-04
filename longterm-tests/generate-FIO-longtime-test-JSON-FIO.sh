#!/bin/bash

k="kubectl"
ns="test-$RANDOM"

profiles_dir="./profiles"

echo "Using NS $ns"
$k create ns $ns


echo "Creating FIO profile as ConfigMap: $profile"
cm=$(find $profiles_dir -type f -name '*.fio' | sed "s/^\(.*\)/--from-file=\1 /" | tr -d '\n')

echo "Creating FIO profiles as ConfigMaps"
echo $cm
$k -n $ns create configmap fio-profiles &> /dev/null
$k -n $ns create configmap fio-profiles $cm -o yaml --dry-run | $k -n $ns replace -f -

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


num_pods=3
echo "Creating NginX deployment"
$k create -n $ns -f- <<END
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-fio
  labels:
    app: nginx
spec:
  replicas: $num_pods
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
          mountPath: /tmp/fio
      volumes:
      - name: docroot
        persistentVolumeClaim:
          claimName: shared-vol
      - name: fio-conf
        configMap:
          name: fio-profiles
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

sleep 60
while ! echo "$($k -n $ns get deploy nginx-fio --no-headers | awk '{print $2}')" | grep -q "$num_pods/$num_pods"; do
    echo "Waiting for Pods to come up"
    sleep 1
done

index=/usr/share/nginx/html/index.html

iterations=0
while true; do
    if [ $(( $iterations % 2 )) -eq 0 ]; then
        echo "Checking Pods availability"
        if  echo "$($k -n $ns get deploy nginx-fio --no-headers | awk '{print $2}')" | grep -q "0/"; then
            echo "No pods are available, sleeping 60s"
            $k -n $ns get deploy nginx-fio
            sleep 60
        fi
    fi

    pods="$( $k get pod -n $ns --no-headers -ocustom-columns=_:.metadata.name -lapp=nginx )"
    for path in $profiles_dir/*.fio; do
        counter=0
        profile="$(echo $path | rev | cut -d'/' -f1 | rev)"

        for p in $pods; do
            echo "Trigger FIO profile $profile in $p"
            $k -n $ns exec $p -- /bin/sh -c "fio --output-format=json /tmp/fio/$profile > /usr/share/nginx/html/out-$counter"
            $k -n $ns exec $p -- /bin/sh -c "date >> $index && echo \"<br>\" $profile \"<br>\" >> $index"
            $k -n $ns exec $p -- /bin/sh -c "grep \"iops\\|bw\" /usr/share/nginx/html/out-$counter >> $index "
            $k -n $ns exec $p -- /bin/sh -c "echo \"<br>\" >> $index"
            sleep 30
            (( ++counter ))
        done
    done

    sleep 60
    (( ++iterations ))
done
