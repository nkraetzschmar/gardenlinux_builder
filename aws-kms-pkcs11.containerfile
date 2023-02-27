ARG base
FROM $base AS aws-kms-pkcs11
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends build-essential awscli ca-certificates cmake git libcurl4-openssl-dev libengine-pkcs11-openssl libjson-c-dev libssl-dev libp11-kit-dev libp11-dev zlib1g-dev
RUN git clone --depth=1 --recurse-submodules -b 1.11.25 https://github.com/aws/aws-sdk-cpp
RUN mkdir aws-sdk-cpp/.build && cd aws-sdk-cpp/.build && cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DBUILD_ONLY="kms;acm-pca" .. && make -j "$(nproc)" install
RUN git clone --depth=1 -b v0.0.10 https://github.com/JackOfMostTrades/aws-kms-pkcs11
RUN cd aws-kms-pkcs11 && make -j "$(nproc)" AWS_SDK_STATIC=y install
