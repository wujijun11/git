package cn.tangsynth.remote;
/** Dependency-free codec, also used by the desktop consistency test. */
public final class Protocol {
    public static final String SERVICE="6e400001-b5a3-f393-e0a9-e50e24dcca9e";
    public static final String RX="6e400002-b5a3-f393-e0a9-e50e24dcca9e";
    public static final String TX="6e400003-b5a3-f393-e0a9-e50e24dcca9e";
    public static int crc(byte[] a,int from,int to){int c=0;for(int i=from;i<to;i++){c^=a[i]&255;for(int b=0;b<8;b++)c=((c&128)!=0?(c<<1)^7:c<<1)&255;}return c;}
    public static byte[] encode(int seq,int op,byte[] payload){if(seq<0||seq>255||op<0||op>255||payload.length>10)throw new IllegalArgumentException("packet range");byte[] a=new byte[16];a[0]=(byte)165;a[1]=90;a[2]=1;a[3]=(byte)seq;a[4]=(byte)op;System.arraycopy(payload,0,a,5,payload.length);a[15]=(byte)crc(a,2,15);return a;}
    public static boolean valid(byte[] a){return a.length==16&&(a[0]&255)==165&&a[1]==90&&a[2]==1&&(a[15]&255)==crc(a,2,15);}
    public static String hex(byte[] a){StringBuilder s=new StringBuilder();for(byte b:a)s.append(String.format(java.util.Locale.ROOT,"%02x",b&255));return s.toString();}
    public static byte[] unhex(String s){if(s==null||s.length()!=32||!s.matches("[0-9a-fA-F]+"))throw new IllegalArgumentException("requires 16-byte packet");byte[] a=new byte[16];for(int i=0;i<16;i++)a[i]=(byte)Integer.parseInt(s.substring(i*2,i*2+2),16);if(!valid(a))throw new IllegalArgumentException("packet CRC/version");return a;}
    private Protocol() {}
}
