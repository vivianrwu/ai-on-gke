#!/bin/bash

set -e
export KAGGLE_CONFIG_DIR="/kaggle"
export HUGGINGFACE_TOKEN_DIR="/huggingface"
INFERENCE_SERVER="jetstream-maxtext"
BUCKET_NAME=""
MODEL_PATH=""

print_usage() {
    echo "Usage: $0 [ -b BUCKET_NAME ] [ -s INFERENCE_SERVER ] [ -m MODEL_PATH ] [ -n MODEL_NAME ] [ -h HUGGINGFACE ] [ -q QUANTIZE_WEIGHTS ] [ -t QUANTIZE_TYPE ] [ -v VERSION ] [ -i INPUT_DIRECTORY ] [ -o OUTPUT_DIRECTORY ]"
    echo "Options:"
    echo "  -b, --bucket_name: [string] The GSBucket name to store checkpoints, without gs://."
    echo "  -s, --inference_server: [string] The name of the inference server that serves your model."
    echo "  -m, --model_path: [string] The model path."
    echo "  -n, --model_name: [string] The model name."
    echo "  -h, --huggingface: [bool] The model is from Hugging Face."
    echo "  -t, --quantize_type: [string] The type of quantization."
    echo "  -q, --quantize_weights: [bool] The checkpoint is to be quantized."
    echo "  -i, --input_directory: [string] The input directory."
    echo "  -o, --output_directory: [string] The output directory."
    echo "  -u, --meta_url: [string] The url from Meta."
    echo "  -v, --version: [string] The version of repository."
}

print_inference_server_unknown() {
    echo "Enter a valid inference server [ -s --inference_server ]"
    echo "Options:"
    echo " jetstream-maxtext"
    echo " jetstream-pytorch"
    exit 1
}

check_gsbucket() {
    BUCKET_NAME=$1
    if [ -z $BUCKET_NAME ]; then
        echo "BUCKET_NAME is empty, please provide a GSBucket"
        exit 1
    fi
}

check_model_path() {
    MODEL_PATH=$1
    if [ -z $MODEL_PATH ]; then
        echo "MODEL_PATH is empty, please provide the model path"
        exit 1
    fi
}

download_kaggle_checkpoint() {
    BUCKET_NAME=$1
    MODEL_PATH=$2
    export MODEL_NAME=$(echo ${MODEL_PATH} | awk -F'/' '{print $2}')
    export VARIATION_NAME=$(echo ${MODEL_PATH} | awk -F'/' '{print $4}')
    export MODEL_SIZE=$(echo ${VARIATION_NAME} | awk -F'-' '{print $1}')

    mkdir -p /data/${MODEL_NAME}_${VARIATION_NAME}
    kaggle models instances versions download ${MODEL_PATH} --untar -p /data/${MODEL_NAME}_${VARIATION_NAME}
    echo -e "\nCompleted extraction to /data/${MODEL_NAME}_${VARIATION_NAME}"

    gcloud storage rsync --recursive --no-clobber /data/${MODEL_NAME}_${VARIATION_NAME} gs://${BUCKET_NAME}/base/${MODEL_NAME}_${VARIATION_NAME}
    echo -e "\nCompleted copy of data to gs://${BUCKET_NAME}/base/${MODEL_NAME}_${VARIATION_NAME}"
}

download_huggingface_checkpoint() {
    MODEL_PATH=$1
    MODEL_NAME=$2

    INPUT_CKPT_DIR_LOCAL=/base/

    if [ ! -d "/base" ]; then
        mkdir /base/
    fi 
    huggingface-cli login --token $(cat ${HUGGINGFACE_TOKEN_DIR}/HUGGINGFACE_TOKEN)
    huggingface-cli download ${MODEL_PATH} --local-dir ${INPUT_CKPT_DIR_LOCAL}

    echo "Completed downloading model ${MODEL_PATH}"

    if [[ $MODEL_NAME == *"llama"* ]]; then
        if [[ $MODEL_NAME == "llama-2" ]]; then
            TOKENIZER_PATH=/base/tokenizer.model
            if [[ $MODEL_PATH != *"hf"* ]]; then
                HUGGINGFACE="False"
            fi
        else
            TOKENIZER_PATH=/base/original/tokenizer.model
        fi
    elif [[ $MODEL_NAME == *"gemma"* ]]; then
        TOKENIZER_PATH=/base/tokenizer.model
        if [[ $MODEL_PATH == *"gemma-2b-it-pytorch"* ]]; then
            huggingface-cli download google/gemma-2b-pytorch config.json \
            --local-dir ${INPUT_CKPT_DIR_LOCAL}
        fi
    else
        echo -e "Unclear of tokenizer.model for ${MODEL_NAME}. May have to manually upload."
    fi
}

download_meta_checkpoint() {
    echo "Downloading checkpoint $MODEL_PATH from Meta..."
    META_URL=$1
    MODEL_PATH=$2
    echo -e "$META_URL" | llama download --source meta --model-id $MODEL_PATH
}

convert_maxtext_checkpoint() {
    BUCKET_NAME=$1
    MODEL_PATH=$2
    MODEL_NAME=$3
    OUTPUT_CKPT_DIR=$4
    VERSION=$5
    HUGGINGFACE=$6
    META_URL=$7
    QUANTIZE_TYPE=$8
    QUANTIZE_WEIGHTS=$9

    echo -e "\nbucket name=${BUCKET_NAME}"
    echo -e "\nmodel path=${MODEL_PATH}"
    echo -e "\nmodel name=${MODEL_NAME}"
    echo -e "\nversion=${VERSION}"
    echo -e "\noutput ckpt dir=${OUTPUT_CKPT_DIR}"
    echo -e "\nhuggingface=${HUGGINGFACE}"
    echo -e "\nurl=${META_URL}"

    if [ -z $VERSION ]; then
        VERSION=main
    fi

    git clone https://github.com/google/maxtext.git

    # checkout stable MaxText commit
    cd maxtext
    git checkout ${VERSION}
    python3 -m pip install -r requirements.txt

    if [[ $VERSION == "jetstream-v0.2.2" || $VERSION == "jetstream-v0.2.1" || $VERSION == "jetstream-v0.2.0" ]]; then
        pip3 install orbax-checkpoint==0.5.20
    fi

    echo -e "\nCloned MaxText repository and completed installing requirements"

    if [[ $MODEL_PATH == *"gemma"* ]]; then
        download_kaggle_checkpoint "$BUCKET_NAME" "$MODEL_PATH"
        OUTPUT_CKPT_DIR_SCANNED=gs://${BUCKET_NAME}/final/scanned/${MODEL_NAME}_${VARIATION_NAME}
        OUTPUT_CKPT_DIR_UNSCANNED=gs://${BUCKET_NAME}/final/unscanned/${MODEL_NAME}_${VARIATION_NAME}

        python3 MaxText/convert_gemma_chkpt.py \
        --base_model_path gs://${BUCKET_NAME}/base/${MODEL_NAME}_${VARIATION_NAME}/${VARIATION_NAME} \
        --maxtext_model_path=${OUTPUT_CKPT_DIR_SCANNED} \
        --model_size ${MODEL_SIZE}
        echo -e "\nCompleted conversion of checkpoint to gs://${BUCKET_NAME}/final/scanned/${MODEL_NAME}_${VARIATION_NAME}"

        MAXTEXT_MODEL_NAME=${MODEL_NAME}-${MODEL_SIZE}

    elif [[ $MODEL_PATH == *"Llama"* ]]; then

        if [ $HUGGINGFACE == "True" ]; then
            echo "Checkpoint weights are from HuggingFace"
            download_huggingface_checkpoint "$MODEL_PATH" "$MODEL_NAME"

        else
            echo "Checkpoint weights are from Meta, use llama CLI"

            if [ -z $META_URL ]; then
                echo "META_URL is empty, please provide the Meta url by visiting https://www.llama.com/llama-downloads/ and agreeing to the Terms and Conditions."
                exit 1
            fi
            echo "META_URL: $META_URL"

            INPUT_CKPT_DIR_LOCAL=/root/.llama/checkpoints/$MODEL_PATH/
            INPUT_CKPT_DIR_LOCAL=${INPUT_CKPT_DIR_LOCAL//":"/"-"}
            download_meta_checkpoint "$META_URL" "$MODEL_PATH"
        fi

        echo "Setting model size for $MODEL_PATH"
        if [[ $MODEL_NAME == "llama-2" ]]; then
            TOKENIZER="assets/tokenizer.llama2"
            if [[ $MODEL_PATH == *"7B"* ]] || [[ $MODEL_PATH == *"7b"* ]]; then
                MODEL_SIZE="llama2-7b"
            elif [[ $MODEL_PATH == *"13B"* ]] || [[ $MODEL_PATH == *"13b"* ]]; then
                MODEL_SIZE="llama2-13b"
            elif [[ $MODEL_PATH == *"70B"* ]] || [[ $MODEL_PATH == *"70b"* ]]; then
                MODEL_SIZE="llama2-70b"
            else
                echo -e "\nUnclear llama2 model: $MODEL_PATH"
            fi

        elif [[ $MODEL_NAME == "llama-3" ]]; then
            TOKENIZER="assets/tokenizer_llama3.tiktoken"
            if [[ $MODEL_PATH == *"8B"* ]] || [[ $MODEL_PATH == *"8b"* ]]; then
                MODEL_SIZE="llama3-8b"
            elif [[ $MODEL_PATH == *"70B"* ]] || [[ $MODEL_PATH == *"70b"* ]]; then
                MODEL_SIZE="llama3-70b"
            else
                echo -e "\nUnclear llama3 model: $MODEL_PATH"
            fi

        elif [[ $MODEL_NAME == "llama-3.1" ]]; then
            TOKENIZER="assets/tokenizer_llama3.tiktoken"
            if [[ $MODEL_PATH == *"8B"* ]] || [[ $MODEL_PATH == *"8b"* ]]; then
                MODEL_SIZE="llama3.1-8b"
            elif [[ $MODEL_PATH == *"70B"* ]] || [[ $MODEL_PATH == *"70b"* ]]; then
                MODEL_SIZE="llama3.1-70b"
            elif [[ $MODEL_PATH == *"405B"* ]] || [[ $MODEL_PATH == *"405b"* ]]; then
                MODEL_SIZE="llama3.1-405b"
            else
                echo -e "\nUnclear llama3.1 model: $MODEL_PATH"
            fi
        
        elif [[ $MODEL_NAME == "llama-3.3" ]]; then
            TOKENIZER="assets/tokenizer_llama3.tiktoken"
            if [[ $MODEL_PATH == *"70B"* ]] || [[ $MODEL_PATH == *"70b"* ]]; then
                MODEL_SIZE="llama3.3-70b"
            else
                echo -e "\nUnclear llama3.3 model: $MODEL_PATH"
            fi

        else
            echo -e "\nUnclear llama model"
        fi

        echo "Model size for $MODEL_PATH is $MODEL_SIZE"

        OUTPUT_CKPT_DIR_UNSCANNED=${OUTPUT_CKPT_DIR}/bf16
        TOKENIZER_PATH=${INPUT_CKPT_DIR_LOCAL}/tokenizer.model

        pip3 install torch
        echo -e "\ninput dir=${INPUT_CKPT_DIR_LOCAL}"
        echo -e "\nmaxtext model path=${OUTPUT_CKPT_DIR_UNSCANNED}"
        echo -e "\nmodel path=${MODEL_PATH}"
        echo -e "\nmodel size=${MODEL_SIZE}"

        export JAX_PLATFORMS=cpu
        cd /maxtext/
        python3 MaxText/llama_ckpt_conversion_inference_only.py \
        --base-model-path ${INPUT_CKPT_DIR_LOCAL} \
        --maxtext-model-path ${OUTPUT_CKPT_DIR_UNSCANNED} \
        --model-size ${MODEL_SIZE}
        echo -e "\nCompleted conversion of checkpoint to ${OUTPUT_CKPT_DIR_UNSCANNED}/0/items"

        gcloud storage cp ${TOKENIZER_PATH} ${OUTPUT_CKPT_DIR_UNSCANNED}

        touch commit_success.txt
        gcloud storage cp commit_success.txt ${OUTPUT_CKPT_DIR_UNSCANNED}/0/items

        LOAD_PARAMS_PATH="${OUTPUT_CKPT_DIR_UNSCANNED}/0/items"

        if [ -z $QUANTIZE_WEIGHTS ]; then
            QUANTIZE_WEIGHTS="False"
        fi
        echo -e "Quantize weights: ${QUANTIZE_WEIGHTS}"
        VALID_QUANTIZATIONS=("int8" "int8w" "int4w" "intmp" "fp8")
        if [ $QUANTIZE_WEIGHTS == "True" ]; then
            # quantize_type is required, the default is bf16
            VALID="False"
            for quantization in $"${VALID_QUANTIZATIONS[@]}"; do
                if [ $QUANTIZE_TYPE == "$quantization" ]; then
                    VALID="True"
                    SAVE_QUANT_PARAMS_PATH="${OUTPUT_CKPT_DIR}/${QUANTIZE_TYPE}"
                    python3 MaxText/decode.py \
                    MaxText/configs/base.yml \
                    tokenizer_path=${TOKENIZER} \
                    load_parameters_path=${LOAD_PARAMS_PATH} \
                    max_prefill_predict_length=1024 \
                    max_target_length=2048 \
                    model_name=${MODEL_SIZE} \
                    ici_fsdp_parallelism=1 \
                    ici_autoregressive_parallelism=1 \
                    ici_tensor_parallelism=-1 \
                    scan_layers=false \
                    weight_dtype=bfloat16 \
                    per_device_batch_size=1 \
                    attention=dot_product \
                    quantization=${QUANTIZE_TYPE} \
                    save_quantized_params_path=${SAVE_QUANT_PARAMS_PATH} \
                    async_checkpointing=false \
                    quantize_only=true
                fi
            done
            if [ $VALID == "False" ]; then
                echo -e "Quantize weights was True but an invalid quantization was provided: $QUANTIZE_TYPE. Valid quantizations: $VALID_QUANTIZATIONS"
            fi
        fi

    else
        echo -e "\nUnclear model"
    fi

    if [[ $MODEL_PATH == *"gemma"* ]]; then
        RUN_NAME=0

        python3 MaxText/generate_param_only_checkpoint.py MaxText/configs/base.yml force_unroll=true model_name=${MAXTEXT_MODEL_NAME} async_checkpointing=false run_name=${RUN_NAME} load_parameters_path=${OUTPUT_CKPT_DIR_SCANNED}/0/items base_output_directory=${OUTPUT_CKPT_DIR_UNSCANNED}
        echo -e "\nCompleted unscanning checkpoint to ${OUTPUT_CKPT_DIR_UNSCANNED}/${RUN_NAME}/checkpoints/0/items"
    fi
}

convert_pytorch_checkpoint() {
    MODEL_PATH=$1
    MODEL_NAME=$2
    HUGGINGFACE=$3
    INPUT_CKPT_DIR=$4
    OUTPUT_CKPT_DIR=$5
    QUANTIZE_TYPE=$6
    QUANTIZE_WEIGHTS=$7
    PYTORCH_VERSION=$8

    if [ -z $PYTORCH_VERSION ]; then
        PYTORCH_VERSION=jetstream-v0.2.3
    fi

    CKPT_PATH="$(echo ${INPUT_CKPT_DIR} | awk -F'gs://' '{print $2}')"
    BUCKET_NAME="$(echo ${CKPT_PATH} | awk -F'/' '{print $1}')"

    TO_REPLACE=gs://${BUCKET_NAME}

    OUTPUT_CKPT_DIR_LOCAL=/pt-ckpt/

    git clone https://github.com/google/jetstream-pytorch.git

    # checkout stable Pytorch commit
    cd /jetstream-pytorch
    git checkout ${PYTORCH_VERSION}
    bash install_everything.sh
    echo -e "\nCloned JetStream PyTorch repository and completed installing requirements"

    echo -e "\nRunning conversion script to convert model weights. This can take a couple minutes..."

    if [ $HUGGINGFACE == "True" ]; then
        echo "Checkpoint weights are from HuggingFace"
        download_huggingface_checkpoint "$MODEL_PATH" "$MODEL_NAME"
    else
        HUGGINGFACE="False"

        # Example: 
        # the input checkpoint directory is gs://jetstream-checkpoints/llama-2-7b/base-checkpoint/
        # the local checkpoint directory will be /models/llama-2-7b/base-checkpoint/
        # INPUT_CKPT_DIR_LOCAL=${INPUT_CKPT_DIR/${TO_REPLACE}/${MODEL_PATH}}
        INPUT_CKPT_DIR_LOCAL=${INPUT_CKPT_DIR/${TO_REPLACE}/${MODEL_PATH}}
        TOKENIZER_PATH=${INPUT_CKPT_DIR_LOCAL}/tokenizer.model
    fi

    if [ -z $QUANTIZE_WEIGHTS ]; then
        QUANTIZE_WEIGHTS="False"
    fi

    # Possible quantizations:
    # 1. quantize_weights = False, we run without specifying quantize_type
    # 2. quantize_weights = True, we run without specifying quantize_type to use the default int8_per_channel
    # 3. quantize_weights = True, we run and specify quantize_type
    # We can use the same command for case #1 and #2, since both have quantize_weights set without needing to specify quantize_type

    echo -e "\n quantize weights: ${QUANTIZE_WEIGHTS}"
    if [ $QUANTIZE_WEIGHTS == "True" ]; then 
        # quantize_type is required, it will be set to the default value if not turned on
        if [ -n $QUANTIZE_TYPE ]; then
            python3 -m convert_checkpoints \
            --model_name=${MODEL_NAME} \
            --input_checkpoint_dir=${INPUT_CKPT_DIR_LOCAL} \
            --output_checkpoint_dir=${OUTPUT_CKPT_DIR_LOCAL} \
            --quantize_type=${QUANTIZE_TYPE} \
            --quantize_weights=${QUANTIZE_WEIGHTS} \
            --from_hf=${HUGGINGFACE}
        fi
    else
        # quantize_weights should be false, but if not the convert_checkpoints script will catch it
        python3 -m convert_checkpoints \
        --model_name=${MODEL_NAME} \
        --input_checkpoint_dir=${INPUT_CKPT_DIR_LOCAL} \
        --output_checkpoint_dir=${OUTPUT_CKPT_DIR_LOCAL} \
        --quantize_weights=${QUANTIZE_WEIGHTS} \
        --from_hf=${HUGGINGFACE}
    fi
    
    echo -e "\nCompleted conversion of checkpoint to ${OUTPUT_CKPT_DIR_LOCAL}"
    echo -e "\nUploading converted checkpoint from local path ${OUTPUT_CKPT_DIR_LOCAL} to GSBucket ${OUTPUT_CKPT_DIR}"
    

    gcloud storage cp -r ${OUTPUT_CKPT_DIR_LOCAL}/* ${OUTPUT_CKPT_DIR}
    gcloud storage cp ${TOKENIZER_PATH} ${OUTPUT_CKPT_DIR}
    echo -e "\nCompleted uploading converted checkpoint from local path ${OUTPUT_CKPT_DIR_LOCAL} to GSBucket ${OUTPUT_CKPT_DIR}"
}

CMD_ARGS=$(getopt -o "xb:s:m:n:h:t:q:v:i:o:u:" --long "bucket_name:,inference_server:,model_name:,
model_path:,huggingface:,quantize_type:,quantize_weights:,version:,input_directory:,output_directory:,
meta_url:,help," -- "$@")
eval set -- "$CMD_ARGS"

while true; do
    case "$1" in
        -b | --bucket_name) BUCKET_NAME="$2"; shift 2 ;;
        -s | --inference_server) INFERENCE_SERVER="$2"; shift 2 ;;
        -m | --model_path) MODEL_PATH="$2"; shift 2 ;;
        -n | --model_name) MODEL_NAME="$2"; shift 2 ;;
        -h | --huggingface) HUGGINGFACE="$2"; shift 2 ;;
        -t | --quantize_type) QUANTIZE_TYPE="$2"; shift 2 ;;
        -q | --quantize_weights) QUANTIZE_WEIGHTS="$2"; shift 2 ;;
        -v | --version) VERSION="$2"; shift 2 ;;
        -i | --input_directory) INPUT_DIRECTORY="$2"; shift 2 ;;
        -o | --output_directory) OUTPUT_DIRECTORY="$2"; shift 2 ;;
        -u | --meta_url) META_URL="$2"; shift 2 ;;
        -x | --help) print_usage; exit 0 ;;
        --) shift; break ;;
        *) echo "Internal error!" exit 1 ;;
    esac
done

echo "Inference server is ${INFERENCE_SERVER}"

case ${INFERENCE_SERVER} in 

    jetstream-maxtext)
        check_gsbucket "$BUCKET_NAME"
        check_model_path "$MODEL_PATH"
        convert_maxtext_checkpoint "$BUCKET_NAME" "$MODEL_PATH" "$MODEL_NAME" "$OUTPUT_DIRECTORY" "$VERSION" "$HUGGINGFACE" "$META_URL" "$QUANTIZE_TYPE" "$QUANTIZE_WEIGHTS"
        ;;
    jetstream-pytorch)
        check_model_path "$MODEL_PATH"
        convert_pytorch_checkpoint "$MODEL_PATH" "$MODEL_NAME" "$HUGGINGFACE" "$INPUT_DIRECTORY" "$OUTPUT_DIRECTORY" "$QUANTIZE_TYPE" "$QUANTIZE_WEIGHTS" "$VERSION"
        ;;
    *) print_inference_server_unknown
exit 1 ;;
esac