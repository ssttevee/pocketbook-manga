package fixture;
import java.util.List;
import kotlin.coroutines.Continuation;
import eu.kanade.tachiyomi.source.online.HttpSource;
import eu.kanade.tachiyomi.source.model.*;
import okhttp3.Headers;
import okhttp3.Cookie;
import okhttp3.HttpUrl;
import okhttp3.Request;
import okhttp3.OkHttpClient;
import okhttp3.CompressionInterceptor;
import okhttp3.Gzip;
import okhttp3.brotli.Brotli;
import okhttp3.zstd.Zstd;
import java.util.concurrent.TimeUnit;
import eu.kanade.tachiyomi.network.interceptor.SpecificHostRateLimitInterceptorKt;
public final class FixtureSource extends HttpSource {
  public String getName() { return "PocketManga Test Source"; }
  public long getId() { return 424242; }
  public String getLang() { return "en"; }
  public String getBaseUrl() { return System.getenv().getOrDefault("POCKETMANGA_FIXTURE_SCHEME", "http") + "://" + System.getenv().getOrDefault("POCKETMANGA_FIXTURE_HOST", "127.0.0.1") + ":8765"; }
  private OkHttpClient fixtureClient;
  public synchronized OkHttpClient getClient() {
    if(fixtureClient==null) fixtureClient=SpecificHostRateLimitInterceptorKt.rateLimitHost(super.getClient().newBuilder(), HttpUrl.get(getBaseUrl()), 2, 100L, TimeUnit.MILLISECONDS).addInterceptor(new CompressionInterceptor(Zstd.INSTANCE, Brotli.INSTANCE, Gzip.INSTANCE)).addNetworkInterceptor(new keiyoushi.network.CookieInterceptor(HttpUrl.get(getBaseUrl()).host())).addNetworkInterceptor(new keiyoushi.network.RateLimitInterceptor()).build();
    return fixtureClient;
  }
  private void checkZstd(String stage) {
    try(var response=getClient().newCall(new Request.Builder().url(getBaseUrl()+"/metadata/"+stage).build()).execute()) {
      if(!response.isSuccessful()) throw new java.io.IOException("Metadata HTTP "+response.code());
      if(response.header("Content-Encoding")!=null || !response.body().string().equals("PocketManga zstd metadata fixture\n".repeat(2048))) throw new java.io.IOException("zstd metadata mismatch");
      if (System.getProperty("os.arch").equals("arm")) {
        String maps=java.nio.file.Files.readString(java.nio.file.Path.of("/proc/self/maps"));
        if(!maps.contains("/runtime/lib/libpocketmanga-zstd.so")) throw new java.io.IOException("bundled JNI zstd mapping missing");
      }
      System.err.println("Native libzstd metadata decoded: "+stage);
    } catch(java.io.IOException e) { throw new RuntimeException(e); }
  }
  public boolean getSupportsLatest() { return true; }
  public String getMangaUrl(SManga m) { return getBaseUrl()+m.getUrl(); }
  public String getChapterUrl(SChapter c) { return getBaseUrl()+c.getUrl(); }
  protected Headers.Builder headersBuilder() { return new Headers.Builder().add("X-PocketManga-Fixture", "yes"); }
  private SManga manga() { var m=SManga.Companion.create(); m.setUrl("/story"); m.setTitle("Runtime Fixture Story"); m.setAuthor("PocketManga tests"); return m; }
  private SChapter chapter() { var c=SChapter.Companion.create(); c.setUrl("/chapter/1"); c.setName("Chapter 1"); c.setChapter_number(1); return c; }
  public Object getPopularManga(int page, Continuation<? super MangasPage> c) { checkZstd("browse"); return new MangasPage(List.of(manga()), false); }
  public Object getLatestUpdates(int page, Continuation<? super MangasPage> c) { return getPopularManga(page,c); }
  public Object getSearchManga(int page, String query, FilterList f, Continuation<? super MangasPage> c) { return getPopularManga(page,c); }
  public Object getMangaUpdate(SManga m, List<? extends SChapter> chapters, boolean details, boolean fetchChapters, Continuation<? super SMangaUpdate> c) { if(details) checkZstd("details"); if(fetchChapters) checkZstd("chapters"); return new SMangaUpdate(manga(),List.of(chapter())); }
  protected Request imageRequest(Page page) { return new Request.Builder().url(page.getImageUrl()).headers(getHeaders()).header("Referer", getBaseUrl()+"/chapter/1").build(); }
  private String pageUrl(int index) {
    String route=System.getenv().containsKey("POCKETMANGA_FIXTURE_REDIRECT") ? "/redirect" : "/page.png";
    String mode=System.getenv().containsKey("POCKETMANGA_FIXTURE_CANCEL_RESUME") ? "&stallonce" : "";
    return getBaseUrl()+route+"?"+index+mode;
  }
  public Object getImageUrl(Page page, Continuation<? super String> c) { return pageUrl(page.getIndex()); }
  public Object getPageList(SChapter ch, Continuation<? super List<? extends Page>> c) {
    checkZstd("pages");
    var url=HttpUrl.get(getBaseUrl()+"/page.png");
    getClient().cookieJar().saveFromResponse(url,List.of(new Cookie.Builder().name("fixture-session").value("accepted").hostOnlyDomain(url.host()).path("/").build()));
    return List.of(new Page(0,"/image/0",pageUrl(0),null), new Page(1,"/image/1",null,null), new Page(2,"/image/2",pageUrl(2),null));
  }
}
