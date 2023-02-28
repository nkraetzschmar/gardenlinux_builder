ARG base
FROM $base
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends binutils-aarch64-linux-gnu binutils-x86-64-linux-gnu bsdextrautils cryptsetup datefudge e2fsprogs fdisk mtools sbsigntool systemd qemu-utils
