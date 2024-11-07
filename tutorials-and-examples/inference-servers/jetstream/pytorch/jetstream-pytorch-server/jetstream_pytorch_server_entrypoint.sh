#!/bin/bash
export HUGGINGFACE_TOKEN_DIR="/huggingface"

cd /jetstream-pytorch
huggingface-cli login --token $(cat ${HUGGINGFACE_TOKEN_DIR}/HUGGINGFACE_TOKEN)
jpt serve $@