/**
 * imgproxy request router for CloudFront
 * Routes image optimization requests to imgproxy service
 */
const IMGPROXY_URL = process.env.IMGPROXY_URL;
const SUPPORTED_FORMATS = ['jpg', 'jpeg', 'png', 'webp', 'gif', 'avif'];

export const handler = async (event) => {
  const request = event.Records[0].cf.request;
  const uri = request.uri;
  const params = request.querystring;

  const ext = uri.split('.').pop().toLowerCase();
  if (!SUPPORTED_FORMATS.includes(ext)) {
    return request;
  }

  const accept = request.headers['accept']?.[0]?.value || '';
  const format = accept.includes('avif') ? 'avif'
    : accept.includes('webp') ? 'webp'
    : ext;

  const width = params?.w || '0';
  const height = params?.h || '0';

  request.uri = `/rs:fit:${width}:${height}/f:${format}/plain/s3://${process.env.S3_BUCKET}${uri}`;
  request.origin.custom.domainName = new URL(IMGPROXY_URL).hostname;

  return request;
};
