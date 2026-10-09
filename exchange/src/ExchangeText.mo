/// ExchangeText.mo: every refusal of the exchange's foundation as a stable code and its text in English and Arabic.
/// A client shows the text of the code in the reader's language; the log and the replies carry the code, never a
/// sentence. Codes are never renumbered; a new refusal takes the next code. The battery checks that every code has
/// both texts and that every error maps to a code, with a control that drops one text and must go red.
///
/// Attribution: Thebes Core Team.

import T "ExchangeTypes";

module {

  public type Texts = { en : Text; ar : Text };

  public func code(e : T.Error) : Nat {
    switch (e) {
      case (#InvalidText(_)) 1001; case (#DuplicateMemberCode(_)) 1002; case (#UnknownMember(_)) 1003; case (#MemberNotActive(_)) 1004;
      case (#NoStatusChange) 1005; case (#ExpelledIsFinal(_)) 1006; case (#DuplicateTrader(_)) 1007; case (#UnknownTrader(_)) 1008;
      case (#TraderRevoked(_)) 1009; case (#RightHeld(_)) 1010; case (#RightNotHeld(_)) 1011; case (#InvalidClientCommitment) 1012;
      case (#UnknownAccount(_)) 1013; case (#AccountClosed(_)) 1014; case (#DuplicateSegmentCode(_)) 1015; case (#UnknownSegment(_)) 1016;
      case (#InvalidSchedule(_)) 1017; case (#InvalidRestDays) 1018; case (#DuplicateHoliday(_)) 1019; case (#HolidayInPast(_)) 1020;
      case (#InvalidTickTable(_)) 1021; case (#UnknownTickTable(_)) 1022; case (#DuplicateIsin(_)) 1023; case (#InvalidIsin(_)) 1024;
      case (#InvalidCurrency(_)) 1025; case (#UnknownInstrument(_)) 1026; case (#InstrumentDelisted(_)) 1027; case (#InvalidLot) 1028;
      case (#PriceOffTick(_)) 1029; case (#InvalidPrice) 1030; case (#NotTheChainsClock(_)) 1031; case (#PhaseUnchanged(_)) 1032;
      case (#InvalidUtcOffset) 1033; case (#NotYourMember(_)) 1034;
    }
  };

  /// Every code, in order: the battery walks this list.
  public let codes : [Nat] = [
    1001, 1002, 1003, 1004, 1005, 1006, 1007, 1008, 1009, 1010, 1011, 1012, 1013, 1014, 1015, 1016, 1017,
    1018, 1019, 1020, 1021, 1022, 1023, 1024, 1025, 1026, 1027, 1028, 1029, 1030, 1031, 1032, 1033, 1034,
  ];

  public func texts(c : Nat) : ?Texts {
    switch (c) {
      case 1001 ?{ en = "A text field is empty or too long."; ar = "حقل نصي فارغ أو أطول من المسموح." };
      case 1002 ?{ en = "A member with this code is already admitted."; ar = "يوجد عضو مقبول بهذا الرمز بالفعل." };
      case 1003 ?{ en = "There is no such member."; ar = "لا يوجد عضو بهذا المعرّف." };
      case 1004 ?{ en = "The member is not active."; ar = "العضو غير نشط." };
      case 1005 ?{ en = "The status is already the one requested."; ar = "الحالة هي المطلوبة بالفعل." };
      case 1006 ?{ en = "An expelled member cannot be reinstated."; ar = "لا يمكن إعادة عضو مفصول." };
      case 1007 ?{ en = "This principal is already registered as a trader."; ar = "هذا المعرّف مسجّل بالفعل كمتداول." };
      case 1008 ?{ en = "There is no such trader."; ar = "لا يوجد متداول بهذا المعرّف." };
      case 1009 ?{ en = "The trader's registration is revoked."; ar = "تم إلغاء تسجيل المتداول." };
      case 1010 ?{ en = "The trader already holds the right to trade in this segment."; ar = "يملك المتداول بالفعل حق التداول في هذا القطاع." };
      case 1011 ?{ en = "The trader does not hold the right to trade in this segment."; ar = "لا يملك المتداول حق التداول في هذا القطاع." };
      case 1012 ?{ en = "A client account needs a 32-byte commitment to the client; a house account has none."; ar = "يحتاج حساب العميل إلى التزام من 32 بايت بهوية العميل، ولا يحمل حساب الشركة أي التزام." };
      case 1013 ?{ en = "There is no such account."; ar = "لا يوجد حساب بهذا المعرّف." };
      case 1014 ?{ en = "The account is closed."; ar = "الحساب مغلق." };
      case 1015 ?{ en = "A segment with this code is already defined."; ar = "يوجد قطاع معرّف بهذا الرمز بالفعل." };
      case 1016 ?{ en = "There is no such segment."; ar = "لا يوجد قطاع بهذا المعرّف." };
      case 1017 ?{ en = "The schedule does not cover the day in order without gap or overlap."; ar = "الجدول لا يغطي اليوم بالترتيب دون فجوة أو تداخل." };
      case 1018 ?{ en = "Rest days are weekdays 0 to 6, without repeats, and leave at least one working day."; ar = "أيام الراحة من 0 إلى 6 دون تكرار، مع بقاء يوم عمل واحد على الأقل." };
      case 1019 ?{ en = "This holiday is already declared."; ar = "هذه العطلة معلنة بالفعل." };
      case 1020 ?{ en = "A holiday cannot be declared for a day that has passed."; ar = "لا يمكن إعلان عطلة في يوم مضى." };
      case 1021 ?{ en = "The tick table is not valid."; ar = "جدول وحدات تغير السعر غير صالح." };
      case 1022 ?{ en = "There is no such tick table."; ar = "لا يوجد جدول وحدات تغير سعر بهذا المعرّف." };
      case 1023 ?{ en = "An instrument with this ISIN is already listed."; ar = "توجد ورقة مدرجة بهذا الرمز الدولي بالفعل." };
      case 1024 ?{ en = "The ISIN is not valid (ISO 6166 check digit)."; ar = "الرمز الدولي للورقة المالية غير صالح (رقم التحقق وفق ISO 6166)." };
      case 1025 ?{ en = "The currency is not a three-letter code."; ar = "العملة ليست رمزًا من ثلاثة أحرف." };
      case 1026 ?{ en = "There is no such instrument."; ar = "لا توجد ورقة مالية بهذا المعرّف." };
      case 1027 ?{ en = "The instrument is delisted."; ar = "الورقة المالية مشطوبة." };
      case 1028 ?{ en = "The lot is zero."; ar = "حجم الوحدة صفر." };
      case 1029 ?{ en = "The price is not on the instrument's tick."; ar = "السعر لا يطابق وحدة تغير السعر للورقة." };
      case 1030 ?{ en = "The price is zero."; ar = "السعر صفر." };
      case 1031 ?{ en = "The day and second are not the chain's clock at submission."; ar = "اليوم والثانية لا يطابقان ساعة السلسلة عند التقديم." };
      case 1032 ?{ en = "The segment is already in the phase its schedule names now."; ar = "القطاع في المرحلة التي يحددها جدوله الآن بالفعل." };
      case 1033 ?{ en = "The market's UTC offset is at most fourteen hours either way."; ar = "فرق توقيت السوق عن التوقيت العالمي لا يتجاوز أربع عشرة ساعة في أي اتجاه." };
      case 1034 ?{ en = "A trader acts only for the accounts of its own member."; ar = "لا يتصرف المتداول إلا في حسابات العضو التابع له." };
      case _ null;
    }
  };
}
