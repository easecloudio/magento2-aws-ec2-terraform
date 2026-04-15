/**
 * CloudFront URL normalizer for image optimization requests
 * Normalizes query parameters for cache key consistency
 */
function handler(event) {
  var request = event.request;
  var params = request.querystring;
  var normalized = {};

  var width = params.w && parseInt(params.w.value) > 0
    ? Math.min(parseInt(params.w.value), 3840) : null;
  var height = params.h && parseInt(params.h.value) > 0
    ? Math.min(parseInt(params.h.value), 3840) : null;

  var accept = request.headers['accept'] ? request.headers['accept'].value : '';
  var format = accept.includes('avif') ? 'avif'
    : accept.includes('webp') ? 'webp'
    : 'jpeg';

  if (width)  normalized.w = { value: String(width) };
  if (height) normalized.h = { value: String(height) };
  normalized.f = { value: format };

  request.querystring = normalized;
  return request;
}
