#!/bin/sh

docker build -t rayburgemeestre/nagiosnagvis:v2 .

echo "update docker hub with: docker push rayburgemeestre/nagiosnagvis:v2"
