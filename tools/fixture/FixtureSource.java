package fixture;
import java.util.List;
import kotlin.coroutines.Continuation;
import eu.kanade.tachiyomi.source.online.HttpSource;
import eu.kanade.tachiyomi.source.model.*;
import okhttp3.Headers;
public final class FixtureSource extends HttpSource {
  public String getName() { return "PocketManga Test Source"; }
  public long getId() { return 424242; }
  public String getLang() { return "en"; }
  public String getBaseUrl() { return "http://" + System.getenv().getOrDefault("POCKETMANGA_FIXTURE_HOST", "127.0.0.1") + ":8765"; }
  public boolean getSupportsLatest() { return true; }
  public String getMangaUrl(SManga m) { return getBaseUrl()+m.getUrl(); }
  public String getChapterUrl(SChapter c) { return getBaseUrl()+c.getUrl(); }
  protected Headers.Builder headersBuilder() { return new Headers.Builder().add("X-PocketManga-Fixture", "yes"); }
  private SManga manga() { var m=SManga.Companion.create(); m.setUrl("/story"); m.setTitle("Runtime Fixture Story"); m.setAuthor("PocketManga tests"); return m; }
  private SChapter chapter() { var c=SChapter.Companion.create(); c.setUrl("/chapter/1"); c.setName("Chapter 1"); c.setChapter_number(1); return c; }
  public Object getPopularManga(int page, Continuation<? super MangasPage> c) { return new MangasPage(List.of(manga()), false); }
  public Object getLatestUpdates(int page, Continuation<? super MangasPage> c) { return getPopularManga(page,c); }
  public Object getSearchManga(int page, String query, FilterList f, Continuation<? super MangasPage> c) { return getPopularManga(page,c); }
  public Object getMangaUpdate(SManga m, List<? extends SChapter> chapters, boolean details, boolean fetchChapters, Continuation<? super SMangaUpdate> c) { return new SMangaUpdate(manga(),List.of(chapter())); }
  public Object getPageList(SChapter ch, Continuation<? super List<? extends Page>> c) { return List.of(new Page(0,"",getBaseUrl()+"/page.png",null)); }
}
