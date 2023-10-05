#!/bin/bash
kubectl create -f namespace.yaml
kubectl create -f serviceAccount.yaml
kubectl create -f volume.yaml
kubectl create -f deployment.yaml
kubectl create -f service.yaml
