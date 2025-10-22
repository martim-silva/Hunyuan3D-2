FROM albtaiuti/hunyuan3d-2-docker:latest

WORKDIR /app

COPY . .

RUN pip install -r requirements.txt
RUN pip install -e .
# for texture
RUN cd hy3dgen/texgen/custom_rasterizer
RUN python3 setup.py install
RUN cd ../../..
RUN cd hy3dgen/texgen/differentiable_renderer
RUN python3 setup.py install


ENTRYPOINT ["python", "api_server.py"]

