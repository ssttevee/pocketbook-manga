// Fixture mirrors the inspected Keiyoushi CookieInterceptor's reflective shape.
package keiyoushi.network;
import java.util.List;
import kotlin.Pair;
import kotlin.jvm.functions.Function0;
import okhttp3.*;
public final class CookieInterceptor implements Interceptor {
  private static final class Config {
    private final Function0<String> domain;
    private final Function0<List<Pair<String,String>>> cookies = () -> List.of(new Pair<>("fixture-extra", "present"));
    private Config(String host) { domain = () -> host; }
  }
  private final List<Config> configs;
  public CookieInterceptor(String host) { configs=List.of(new Config(host)); }
  public Response intercept(Chain chain) throws java.io.IOException {
    Request request=chain.request();
    String cookies=request.header("Cookie");
    return chain.proceed(request.newBuilder().header("Cookie",(cookies==null ? "" : cookies+"; ")+"fixture-extra=present").build());
  }
}
