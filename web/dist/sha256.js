(function(root,factory){
  if(typeof module==="object"&&module.exports)module.exports=factory();
  else root.MacNASSHA256=Object.freeze(factory());
})(globalThis,function(){
  "use strict";
  // SHA-256, FIPS 180-4 sections 4.1.2, 4.2.2, 5 and 6.2. Fixed 64-byte work buffer.
  const K=new Uint32Array([
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2]);
  const rotate=(x,n)=>(x>>>n)|(x<<(32-n));
  class SHA256 {
    constructor(){this.words=new Uint32Array([0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]);this.buffer=new Uint8Array(64);this.used=0;this.bytes=0;this.schedule=new Uint32Array(64);}
    block(bytes){
      const w=this.schedule;
      for(let i=0;i<16;i++){const j=i*4;w[i]=(bytes[j]<<24)|(bytes[j+1]<<16)|(bytes[j+2]<<8)|bytes[j+3];}
      for(let i=16;i<64;i++){const a=w[i-15],b=w[i-2];w[i]=(w[i-16]+(rotate(a,7)^rotate(a,18)^(a>>>3))+w[i-7]+(rotate(b,17)^rotate(b,19)^(b>>>10)))>>>0;}
      let[a,b,c,d,e,f,g,h]=this.words;
      for(let i=0;i<64;i++){const t1=(h+(rotate(e,6)^rotate(e,11)^rotate(e,25))+((e&f)^(~e&g))+K[i]+w[i])>>>0,t2=((rotate(a,2)^rotate(a,13)^rotate(a,22))+((a&b)^(a&c)^(b&c)))>>>0;
        h=g;g=f;f=e;e=(d+t1)>>>0;d=c;c=b;b=a;a=(t1+t2)>>>0;}
      for(const [i,v]of[a,b,c,d,e,f,g,h].entries())this.words[i]=(this.words[i]+v)>>>0;
    }
    update(bytes){
      if(!(bytes instanceof Uint8Array)||!Number.isSafeInteger(this.bytes+bytes.length)||this.bytes+bytes.length>16*1024*1024)throw new RangeError("SHA-256 prototype byte limit");
      this.bytes+=bytes.length;
      for(let offset=0;offset<bytes.length;){const count=Math.min(64-this.used,bytes.length-offset);this.buffer.set(bytes.subarray(offset,offset+count),this.used);this.used+=count;offset+=count;
        if(this.used===64){this.block(this.buffer);this.used=0;}}
      return this;
    }
    hex(){
      const copy=new SHA256();copy.words.set(this.words);
      const tail=new Uint8Array(this.used<56?64:128);tail.set(this.buffer.subarray(0,this.used));tail[this.used]=128;
      const view=new DataView(tail.buffer);view.setUint32(tail.length-8,Math.floor(this.bytes/0x20000000));view.setUint32(tail.length-4,(this.bytes*8)>>>0);
      for(let i=0;i<tail.length;i+=64)copy.block(tail.subarray(i,i+64));
      return Array.from(copy.words,v=>v.toString(16).padStart(8,"0")).join("");
    }
  }
  return {SHA256,digest:bytes=>new SHA256().update(bytes).hex()};
});
