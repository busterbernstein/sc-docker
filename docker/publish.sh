#!/usr/bin/env bash
set -eux

# do not publish starcraft:game
VERSION=$(python ../setup.py --version)

docker tag starcraft:wine  bbernstein/copycatsc:wine
docker tag starcraft:bwapi bbernstein/copycatsc:bwapi
docker tag starcraft:java  bbernstein/copycatsc:java
docker tag starcraft:play  bbernstein/copycatsc:play

docker push bbernstein/copycatsc:wine
docker push bbernstein/copycatsc:bwapi
docker push bbernstein/copycatsc:java
docker push bbernstein/copycatsc:play
