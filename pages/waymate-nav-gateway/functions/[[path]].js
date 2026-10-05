export function onRequest({ request, env }) {
  return env.GATEWAY.fetch(request);
}
