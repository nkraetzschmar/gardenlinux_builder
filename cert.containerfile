ARG base
FROM $base
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends efitools gettext git gnupg make openssl python3 python3-venv uuid-runtime

# Prepare virtual environment
ENV VIRTUAL_ENV=/opt/venv
RUN python3 -m venv $VIRTUAL_ENV
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

RUN pip install git+https://github.com/awslabs/python-uefivars
