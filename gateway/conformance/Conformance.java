// Conformance.java: a conformance session from an independent FIX engine (QuickFIX/J 2.3.1) through a member's gateway.
// The engine validates every message it receives against its own FIX 4.4 data dictionary
// (UseDataDictionary=Y): a report that is not well formed is rejected by the engine and never reaches this application,
// so a step that waits for its report fails.
//
// The session, step by step, each printed PASS or FAIL:
//   1  Logon (ResetSeqNumFlag), answered;
//   2  NewOrderSingle A1 (a buy of 10 at price p1): ExecutionReport New;
//   3  OrderCancelReplaceRequest A2 for A1 (20 at price p2): ExecutionReport Replaced, OrigClOrdID A1;
//   4  OrderCancelRequest A3 for A2: ExecutionReport Canceled;
//   5  NewOrderSingle B1 (a buy of 5 at p1), then "CROSS B1" for the orchestrator to sell 5 against it from another
//      member: ExecutionReport Trade, filled, LastQty 5, LastPx p1;
//   6  NewOrderSingle on an instrument the venue does not trade: ExecutionReport Rejected;
//   7  TestRequest T1: Heartbeat with TestReqID T1;
//   8  a gap: the next outgoing sequence number advanced by two, so the gateway asks for a resend, which the engine
//      fills with a SequenceReset-GapFill; then NewOrderSingle C1 (a buy of 1 at p3), answered New;
//   9  the engine asks the gateway to resend from 1 (its expected sequence number set back): the gateway's messages
//      come again with PossDupFlag, no new report is counted twice;
//  10  Logout, answered.
//
//   java -cp <quickfixj jars>:. Conformance <host> <port> <symbol> <account> <p1> <p2> <p3>
//
// An eighth argument prefixes every ClOrdID, so a second session on the same account names new orders.
// The prices are FIX Prices with two decimals, inside the instrument's collars; the reports must carry them as given.
//
// Attribution: Thebes Core Team.

import quickfix.*;
import quickfix.field.*;
import quickfix.fix44.ExecutionReport;
import quickfix.fix44.NewOrderSingle;
import quickfix.fix44.OrderCancelReplaceRequest;
import quickfix.fix44.OrderCancelRequest;
import quickfix.fix44.Heartbeat;

import java.io.ByteArrayInputStream;
import java.time.LocalDateTime;
import java.util.*;
import java.util.concurrent.*;

public class Conformance implements Application {
  final BlockingQueue<Message> reports = new LinkedBlockingQueue<>();
  final BlockingQueue<String> heartbeats = new LinkedBlockingQueue<>();
  final CountDownLatch logon = new CountDownLatch(1);
  final CountDownLatch logout = new CountDownLatch(1);
  volatile int rejectsReceived = 0;
  int failures = 0;

  public void onCreate(SessionID id) {}
  public void onLogon(SessionID id) { logon.countDown(); }
  public void onLogout(SessionID id) { logout.countDown(); }
  public void toAdmin(Message m, SessionID id) {}
  public void fromAdmin(Message m, SessionID id) throws FieldNotFound {
    String t = m.getHeader().getString(MsgType.FIELD);
    if (t.equals("0") && m.isSetField(TestReqID.FIELD)) heartbeats.add(m.getString(TestReqID.FIELD));
    if (t.equals("3")) rejectsReceived++;
  }
  public void toApp(Message m, SessionID id) {}
  public void fromApp(Message m, SessionID id) {
    try {
      // a resent report (PossDupFlag) is the one already counted
      if (m.getHeader().isSetField(PossDupFlag.FIELD) && m.getHeader().getBoolean(PossDupFlag.FIELD)) return;
    } catch (FieldNotFound e) { throw new RuntimeException(e); }
    reports.add(m);
  }

  void check(boolean ok, String what) {
    System.out.println((ok ? "PASS " : "FAIL ") + what);
    System.out.flush();
    if (!ok) failures++;
  }

  Message next(String what) throws InterruptedException {
    Message m = reports.poll(30, java.util.concurrent.TimeUnit.SECONDS);
    if (m == null) { check(false, what + ": no report within 30 s"); }
    return m;
  }

  static String s(Message m, int tag) { try { return m.getString(tag); } catch (FieldNotFound e) { return ""; } }

  NewOrderSingle order(String cl, String symbol, String account, char side, int qty, String price) {
    NewOrderSingle o = new NewOrderSingle(new ClOrdID(cl), new Side(side), new TransactTime(LocalDateTime.now()), new OrdType(OrdType.LIMIT));
    o.set(new Symbol(symbol)); o.set(new Account(account)); o.set(new OrderQty(qty)); o.set(new Price(Double.parseDouble(price)));
    o.set(new TimeInForce(TimeInForce.GOOD_TILL_CANCEL));
    return o;
  }

  public static void main(String[] args) throws Exception {
    String host = args[0], port = args[1], symbol = args[2], account = args[3], p1 = args[4], p2 = args[5], p3 = args[6], px = args.length > 7 ? args[7] : "";
    String cfg = "[default]\nConnectionType=initiator\nSocketConnectHost=" + host + "\nSocketConnectPort=" + port +
      "\nBeginString=FIX.4.4\nSenderCompID=CLIENT\nTargetCompID=THEBES\nHeartBtInt=30\nResetOnLogon=Y\nUseDataDictionary=Y\n" +
      "DataDictionary=FIX44.xml\nValidateUserDefinedFields=Y\nStartTime=00:00:00\nEndTime=00:00:00\nReconnectInterval=60\n[session]\n";
    SessionSettings settings = new SessionSettings(new ByteArrayInputStream(cfg.getBytes()));
    Conformance app = new Conformance();
    SocketInitiator initiator = new SocketInitiator(app, new MemoryStoreFactory(), settings, new ScreenLogFactory(false, false, false), new DefaultMessageFactory());
    initiator.start();
    app.check(app.logon.await(30, java.util.concurrent.TimeUnit.SECONDS), "1 Logon answered");
    SessionID id = initiator.getSessions().get(0);
    Session session = Session.lookupSession(id);

    Session.sendToTarget(app.order((px + "A1"), symbol, account, Side.BUY, 10, p1), id);
    Message r = app.next("2 New for A1");
    app.check(r != null && s(r, 150).equals("0") && s(r, 39).equals("0") && s(r, 11).equals(px + "A1") && s(r, 151).equals("10"), "2 ExecutionReport New, A1, 10 open");
    String orderId = r == null ? "" : s(r, 37);

    OrderCancelReplaceRequest g = new OrderCancelReplaceRequest(new OrigClOrdID(px + "A1"), new ClOrdID(px + "A2"), new Side(Side.BUY), new TransactTime(LocalDateTime.now()), new OrdType(OrdType.LIMIT));
    g.set(new Symbol(symbol)); g.set(new Account(account)); g.set(new OrderQty(20)); g.set(new Price(Double.parseDouble(p2))); g.set(new OrderID(orderId));
    Session.sendToTarget(g, id);
    r = app.next("3 Replaced");
    app.check(r != null && s(r, 150).equals("5") && s(r, 11).equals(px + "A2") && s(r, 41).equals(px + "A1") && s(r, 38).equals("20") && s(r, 44).equals(p2), "3 ExecutionReport Replaced, A2 for A1, 20 at " + p2);

    OrderCancelRequest f = new OrderCancelRequest(new OrigClOrdID(px + "A2"), new ClOrdID(px + "A3"), new Side(Side.BUY), new TransactTime(LocalDateTime.now()));
    f.set(new Symbol(symbol)); f.set(new OrderID(orderId));
    Session.sendToTarget(f, id);
    r = app.next("4 Canceled");
    app.check(r != null && s(r, 150).equals("4") && s(r, 39).equals("4"), "4 ExecutionReport Canceled");

    Session.sendToTarget(app.order((px + "B1"), symbol, account, Side.BUY, 5, p1), id);
    r = app.next("5 New for B1");
    app.check(r != null && s(r, 150).equals("0") && s(r, 11).equals(px + "B1"), "5 ExecutionReport New, B1");
    System.out.println("CROSS " + px + "B1"); System.out.flush();
    r = app.next("5 Trade for B1");
    app.check(r != null && s(r, 150).equals("F") && s(r, 39).equals("2") && s(r, 32).equals("5") && s(r, 31).equals(p1) && s(r, 14).equals("5"),
      "5 ExecutionReport Trade, B1 filled, LastQty 5 at " + p1);

    Session.sendToTarget(app.order((px + "X1"), "999", account, Side.BUY, 1, p1), id);
    r = app.next("6 Rejected");
    app.check(r != null && s(r, 150).equals("8") && s(r, 39).equals("8"), "6 ExecutionReport Rejected for an instrument the venue does not trade");

    session.generateTestRequest("T1");
    String hb = app.heartbeats.poll(30, java.util.concurrent.TimeUnit.SECONDS);
    app.check("T1".equals(hb), "7 Heartbeat with TestReqID T1");

    // a gap: two sequence numbers skipped; the gateway asks for them and the engine fills the gap
    session.setNextSenderMsgSeqNum(session.getExpectedSenderNum() + 2);
    Session.sendToTarget(app.order((px + "C1"), symbol, account, Side.BUY, 1, p3), id);
    r = app.next("8 New for C1 after the gap");
    app.check(r != null && s(r, 150).equals("0") && s(r, 11).equals(px + "C1"), "8 the gap filled and C1 answered New");

    // the engine asks for the gateway's messages again
    int before = app.reports.size();
    session.setNextTargetMsgSeqNum(1);
    session.generateTestRequest("T2");
    String hb2 = app.heartbeats.poll(30, java.util.concurrent.TimeUnit.SECONDS);
    Thread.sleep(2000);
    app.check("T2".equals(hb2) && app.reports.size() == before, "9 the gateway's messages resent with PossDupFlag, no report counted twice");

    session.logout("conformance done");
    app.check(app.logout.await(30, java.util.concurrent.TimeUnit.SECONDS), "10 Logout answered");
    app.check(app.rejectsReceived == 0, "no session Reject received from the gateway");
    initiator.stop();
    System.out.println(app.failures == 0 ? "CONFORMANCE GREEN" : "CONFORMANCE RED: " + app.failures);
    System.exit(app.failures == 0 ? 0 : 1);
  }
}
