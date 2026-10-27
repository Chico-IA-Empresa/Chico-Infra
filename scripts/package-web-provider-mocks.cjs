// Fixture-only process preload. Mounted read-only; never baked into the image.
// Intercept the provider boundary, preserving the real Next route handlers.
const original = globalThis.fetch;
globalThis.fetch = async function(input, options) {
  const url = typeof input === 'string' ? input : input.url || String(input);
  if (url.startsWith('https://api.resend.com/')) {
    if (!url.endsWith('/emails')) throw new Error('Unexpected fixture email path');
    const body = JSON.parse(options.body);
    if (body.to !== 'capture@example.com' && !body.to?.includes('capture@example.com')) throw new Error('Unexpected fixture recipient');
    console.log(JSON.stringify({fixtureEmailCaptured: true}));
    return Response.json({id:'fixture-captured'});
  }
  if (url === process.env.BACKEND_URL + '/chat/stream') {
    if (!options.headers.Authorization?.startsWith('Bearer ')) return Response.json({}, {status:401});
    const encoder = new TextEncoder();
    return new Response(new ReadableStream({start(controller) {
      controller.enqueue(encoder.encode('data: '+JSON.stringify({fixture:true,backendHost:new URL(url).host})+'\n\n'));
      setTimeout(()=>{controller.enqueue(encoder.encode('data: [DONE]\n\n'));controller.close();}, 1500);
    }}), {headers:{'Content-Type':'text/event-stream'}});
  }
  return original.call(this,input,options);
};
