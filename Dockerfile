# Create the build image
FROM nimlang/nim:2.2.0 as build

# Copy the wls files to the production image
WORKDIR /node
COPY . .

RUN git config --global http.sslVerify false

RUN nimble install -dy

RUN nimble c -d:chronicles_colors=None --threads:on -d:metrics -d:libp2p_network_protocols_metrics  -d:release main


FROM nimlang/nim:1.6.18

RUN apt-get install cron -y

WORKDIR /node

COPY --from=build /node/main /node/main

COPY cron_runner.sh .

RUN chmod +x cron_runner.sh
RUN chmod +x main

EXPOSE 5000 8008

ENTRYPOINT ["./cron_runner.sh"]