ARG base
FROM $base
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends bsdextrautils datefudge e2fsprogs fdisk mtools qemu-utils
