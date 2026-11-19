# Rebuild lucataco's DeepSeek image using the pinned TensorFold source in this repository.
FROM nvcr.io/nvidia/pytorch:26.07-py3
COPY . /opt/TensorFold/
RUN pip install --no-cache-dir -e '/opt/TensorFold[vision]' \
    && python3 -c "import torch, tensorfold; print('tensorfold', tensorfold.__file__, 'torch', torch.__version__)"
LABEL org.opencontainers.image.title="tensorfold-dsv41" \
      org.opencontainers.image.revision="8e0966e2b09250abe2f6d9cc51edc20630e6eb1a"
